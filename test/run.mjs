import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { environment, temporary } from './location.mjs';
import { validateTls } from './support/tls.mjs';
import { changedFiles, root, selection } from './regions.mjs';

function sameIds(actual, expected) {
  return actual.length === expected.length && new Set(actual).size === actual.length &&
    actual.every(id => expected.includes(id));
}

export function nativeEvidence(selected, report, exitCode) {
  const expected = selected.map(item => item.id);
  const reported = report?.results?.flatMap(result => result.modules.map(id => `test/${id}`)) ?? [];
  const valid = report?.complete === true && [0, 1].includes(exitCode) &&
    report.passed === (exitCode === 0) &&
    sameIds(reported, expected) && report.expectedSuites === report.observedSuites;
  return selected.map(item => {
    const module = item.id.slice(5);
    const result = report?.results?.find(row => row.modules.includes(module));
    const executed = Boolean(result && (result.modules.length > 1
      ? result.completedModules.includes(module) : result.executed && result.executedModules === 1));
    const passed = valid && executed && result.passed &&
      (result.modules.length === 1 || result.moduleCountExact);
    return { ...item, status: passed ? 'passed' : 'failed',
      executed, detail: passed ? '' : result?.error || result?.stderr ||
        (valid ? 'Native leaf failed or did not execute' : 'Native report missing, incomplete or mismatched') };
  });
}

export function matrixEvidence(selected, report, exitCode) {
  const expected = selected.map(item => item.id);
  const reported = report?.rows?.map(row => `${row.file}@${row.mode}`) ?? [];
  const valid = report?.complete === true && report?.inventoryUnchanged === true &&
    [0, 1].includes(exitCode) && report.passed === (exitCode === 0) &&
    sameIds(reported, expected);
  return selected.map(item => {
    const row = report?.rows?.find(entry => `${entry.file}@${entry.mode}` === item.id);
    const executed = Boolean(row?.executedTests);
    const passed = valid && executed && row.passed && row.executedTests === row.expectedTests;
    return { ...item, status: passed ? 'passed' : 'failed',
      executed, expectedTests: row?.expectedTests ?? 0,
      executedTests: row?.executedTests ?? 0,
      detail: passed ? '' : row?.errors?.join('; ') ||
        (valid ? 'Semantic leaf failed or did not execute' : 'Semantic report missing, incomplete or mismatched') };
  });
}

export function summarize(selected, cases) {
  const counts = { selected: selected.length, executed: cases.filter(item => item.executed).length,
    passed: cases.filter(item => item.status === 'passed').length,
    failed: cases.filter(item => item.status === 'failed').length,
    unsupported: cases.filter(item => item.status === 'unsupported').length };
  return { ...counts, complete: cases.length === selected.length,
    successful: selected.length > 0 && counts.executed > 0 && cases.length === selected.length &&
      counts.failed === 0 && counts.passed + counts.unsupported === selected.length };
}

function value(args, name) {
  const inline = args.find(arg => arg.startsWith(name + '='));
  if (inline) return inline.slice(name.length + 1);
  const index = args.indexOf(name);
  return index < 0 ? '' : args[index + 1] || '';
}

function options(args) {
  const name = args[0];
  const allowed = new Set(['--list', '--json', '--mode', '--target', '--base', '--files', '--output', '--stage', '--only']);
  for (let index = 1; index < args.length; index++) {
    const argument = args[index];
    const option = argument.split('=')[0];
    if (!allowed.has(option)) throw Error(`Unknown regional test option: ${argument}`);
    if (!argument.includes('=') && !['--list', '--json'].includes(option)) {
      if (!args[index + 1] || args[index + 1].startsWith('--'))
        throw Error(`Missing value for ${option}`);
      index++;
    }
  }
  const mode = value(args, '--mode');
  const target = value(args, '--target');
  if (mode && !['dev', 'release'].includes(mode)) throw Error('Mode must be dev or release');
  if (target && !['arm', 'riscv'].includes(target))
    throw Error('Target selector currently supports arm or riscv hardware gates');
  const files = value(args, '--files');
  return { name, mode, target, base: value(args, '--base') || 'HEAD',
    files: files ? files.split(',').filter(Boolean) : [], output: value(args, '--output'),
    stage: value(args, '--stage'), only: value(args, '--only'),
    list: args.includes('--list'), json: args.includes('--json') };
}

async function execute(command, args, { cwd = root, env = process.env, timeoutMs = 7200000 } = {}) {
  return new Promise(done => {
    const child = spawn(command, args, { cwd, env, windowsHide: true,
      detached: process.platform !== 'win32', stdio: ['ignore', 'pipe', 'pipe'] });
    const streams = { stdout: [], stderr: [] };
    let bytes = 0, error = '';
    const stop = () => {
      if (!child.pid) return;
      if (process.platform === 'win32') {
        const stopped = spawnSync('taskkill', ['/pid', String(child.pid), '/t', '/f'],
          { windowsHide: true, stdio: 'ignore', timeout: 5000 });
        if (stopped.status !== 0) child.kill('SIGKILL');
      }
      else try { process.kill(-child.pid, 'SIGKILL'); } catch {}
    };
    const timer = setTimeout(() => { error = `Timed out after ${timeoutMs} ms`; stop(); }, timeoutMs);
    for (const stream of ['stdout', 'stderr']) child[stream].on('data', chunk => {
      bytes += chunk.length;
      if (bytes > 64 * 1024 * 1024) { error = 'Regional job output limit exceeded'; stop(); }
      else streams[stream].push(chunk);
    });
    child.once('error', cause => { error = cause.message; });
    child.once('close', code => {
      clearTimeout(timer);
      done({ code, error, stdout: Buffer.concat(streams.stdout).toString(),
        stderr: Buffer.concat(streams.stderr).toString() });
    });
  });
}

function readReport(path) {
  try { return JSON.parse(readFileSync(path, 'utf8')); }
  catch { return null; }
}

function scriptCommand(script, directory, opts) {
  const file = join(root, script.id);
  const args = (script.args ?? []).map(arg => arg.replaceAll('OUTPUT', directory));
  if (script.kind === 'tls' && opts.mode) args.push(`--modes=${opts.mode}`);
  if (script.requires === 'release-stage') {
    if (script.id.endsWith('.ps1')) return ['powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file, '-Stage', opts.stage]];
    return ['sh', [file, join(opts.stage, 'bin/foo')]];
  }
  return [process.execPath, [file, ...args]];
}

function unsupported(script, opts) {
  if (script.requires === 'editor-host' && process.env.FOO_EDITOR_HOST !== '1')
    return 'Set FOO_EDITOR_HOST=1 to run the VS Code Development Host';
  if (script.requires === 'windows-qbe' && process.platform !== 'win32')
    return 'QBE cross-target qualification requires the Windows test host';
  if (script.requires === 'release-stage' && !opts.stage)
    return 'Release staging directory is required (--stage)';
  if (script.id.endsWith('.ps1') && process.platform !== 'win32') return 'Windows host required';
  if (script.id.endsWith('.sh') && process.platform !== 'linux') return 'Linux host required';
  return '';
}

async function main() {
  const opts = options(process.argv.slice(2));
  const files = opts.name === 'changed'
    ? opts.files.length ? opts.files : changedFiles(opts.base) : [];
  const planned = selection([opts.name], { mode: opts.mode, files });
  if (opts.only) {
    if (!planned.selected.some(item => item.id === opts.only))
      throw Error(`Leaf is not selected by ${opts.name}: ${opts.only}`);
    planned.selected = planned.selected.filter(item => item.id === opts.only);
  }
  if (opts.target && !planned.regions.includes('targets'))
    throw Error('--target requires the targets region');
  if (opts.json && opts.list) {
    console.log(JSON.stringify({ regions: planned.regions, selected: planned.selected }, null, 2));
    return;
  }
  for (const item of planned.selected) console.log(`SELECT ${item.id} [${item.region}] ${item.reason}`);
  if (opts.list) return;
  const output = resolve(opts.output || temporary());
  mkdirSync(output, { recursive: true });
  const jobRoot = join(output, 'jobs', randomUUID());
  mkdirSync(jobRoot, { recursive: true });
  writeFileSync(join(output, 'selection.json'), JSON.stringify(planned.selected, null, 2) + '\n');
  const cases = [];
  const sharedEnv = { ...process.env };
  const save = complete => {
    const summary = summarize(planned.selected, cases);
    writeFileSync(join(output, 'report.json'), JSON.stringify({ format: 'foo.test-region.v1',
      regions: planned.regions, changedFiles: files, mode: opts.mode || null,
      target: opts.target || null, jobRoot, complete: complete && summary.complete,
      passed: complete && summary.successful, selected: summary.selected,
      executed: summary.executed, passedCases: summary.passed, failed: summary.failed,
      unsupported: summary.unsupported, cases }, null, 2) + '\n');
  };
  save(false);
  for (const region of planned.regions) {
    const setup = planned.scripts.find(item => item.region === region && item.kind === 'setup' &&
      (planned.selected.some(selected => selected.id === item.id) ||
        planned.selected.some(selected => selected.id.startsWith('test/library/dylib.iv@'))));
    if (setup) {
      const item = planned.selected.find(selected => selected.id === setup.id);
      const directory = join(jobRoot, region, setup.id.replaceAll('/', '-').replace(/\.[^.]+$/, ''));
      mkdirSync(directory, { recursive: true });
      const [command, args] = scriptCommand(setup, directory, opts);
      const result = await execute(command, args, { env: environment(directory, sharedEnv) });
      writeFileSync(join(directory, 'stdout.txt'), result.stdout);
      writeFileSync(join(directory, 'stderr.txt'), result.stderr);
      const report = readReport(join(directory, 'dylib', 'report.json'));
      const library = join(directory, 'dylib', process.platform === 'win32' ? 'increment.dll' : 'increment.so');
      const passed = !result.error && result.code === 0 && report?.complete === true &&
        report.passed === true && report.artifact === library && existsSync(library);
      if (item) cases.push({ ...item, status: passed ? 'passed' : 'failed', executed: result.code !== null,
        detail: passed ? '' : result.error || result.stderr.slice(-2000) || 'Missing dynamic-library fixture' });
      if (passed) sharedEnv.FOO_DYLIB_TEST_PATH = library;
      console.log(`${passed ? 'PASS' : 'FAIL'} ${setup.id}`);
      save(false);
      if (!passed && !item) throw Error('Dynamic-library setup failed for selected semantic fixture');
    }
    const native = planned.selected.filter(item => item.region === region && item.kind === 'native');
    if (native.length) {
      const directory = join(jobRoot, region, 'native');
      mkdirSync(directory, { recursive: true });
      const file = join(directory, 'selection.json');
      writeFileSync(file, JSON.stringify({ ids: native.map(item => item.id.slice(5)) }) + '\n');
      const result = await execute(process.execPath, [join(root, 'test/native/run.mjs'),
        `--selection=${file}`, `--output=${directory}`], { env: environment(directory, sharedEnv) });
      writeFileSync(join(directory, 'stdout.txt'), result.stdout);
      writeFileSync(join(directory, 'stderr.txt'), result.stderr);
      cases.push(...nativeEvidence(native, readReport(join(directory, 'summary.json')),
        result.error ? null : result.code));
      console.log(`${cases.slice(-native.length).every(item => item.status === 'passed') ? 'PASS' : 'FAIL'} ${region}/native`);
      save(false);
    }
    const matrix = planned.selected.filter(item => item.region === region && item.kind === 'matrix');
    if (matrix.length) {
      const directory = join(jobRoot, region, 'matrix');
      mkdirSync(directory, { recursive: true });
      const result = await execute(process.execPath, [join(root, 'test/matrix.mjs'),
        '--modes', opts.only ? matrix[0].id.split('@').at(-1) : opts.mode || 'dev,release',
        ...(opts.only ? [`--filter=${matrix[0].id.split('@')[0]}`] : []),
        '--output', directory], { env: environment(directory, sharedEnv) });
      writeFileSync(join(directory, 'stdout.txt'), result.stdout);
      writeFileSync(join(directory, 'stderr.txt'), result.stderr);
      cases.push(...matrixEvidence(matrix, readReport(join(directory, 'report.json')),
        result.error ? null : result.code));
      console.log(`${cases.slice(-matrix.length).every(item => item.status === 'passed') ? 'PASS' : 'FAIL'} ${region}/matrix`);
      save(false);
    }
    for (const script of planned.scripts.filter(item => item.region === region &&
      item.kind !== 'matrix' && item.kind !== 'setup')) {
      const item = planned.selected.find(entry => entry.id === script.id);
      if (!item) continue;
      const reason = unsupported(script, opts);
      if (reason) {
        cases.push({ ...item, status: 'unsupported', executed: false, detail: reason });
        console.log(`UNSUPPORTED ${script.id}: ${reason}`);
        save(false);
        continue;
      }
      const directory = join(jobRoot, region, script.id.replaceAll('/', '-').replace(/\.[^.]+$/, ''));
      mkdirSync(directory, { recursive: true });
      const [command, args] = scriptCommand(script, directory, opts);
      const env = environment(directory, script.kind === 'tls'
        ? { ...sharedEnv, FOO_TLS_REPORT: join(directory, 'report.json') } : sharedEnv);
      const result = await execute(command, args, { env });
      writeFileSync(join(directory, 'stdout.txt'), result.stdout);
      writeFileSync(join(directory, 'stderr.txt'), result.stderr);
      const counted = script.kind === 'tls' ? readReport(join(directory, 'report.json')) : null;
      const executed = result.code !== null;
      const passed = !result.error && result.code === 0 && (script.kind !== 'tls' ||
        counted?.complete === true && counted?.passed === true && counted.executedTests > 0 &&
        (opts.mode || validateTls(counted).length === 0));
      cases.push({ ...item, status: passed ? 'passed' : 'failed', executed,
        detail: passed ? '' : result.error || result.stderr.slice(-2000) || 'Missing counted report' });
      console.log(`${passed ? 'PASS' : 'FAIL'} ${script.id}`);
      save(false);
    }
  }
  save(true);
  const report = readReport(join(output, 'report.json'));
  console.log(`Regional report: ${join(output, 'report.json')} (${report.passedCases}/${report.selected} passed, ${report.failed} failed, ${report.unsupported} unsupported)`);
  if (!report.passed) process.exitCode = 1;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  await main();
