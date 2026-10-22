import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { cpus, release, totalmem } from 'node:os';
import { dirname, join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..', '..', '..');
const baseline = resolve(process.argv[2] || '');
const candidate = resolve(process.argv[3] || '');
const output = resolve(process.argv[4] || join(root, '.artifacts', 'qbe-cache-latency'));
const pairs = Number(process.argv[5] || 7);
if (process.argv.length < 4 || !Number.isInteger(pairs) || pairs < 2 || pairs > 31)
  throw Error('Usage: node benchmark/compilation/qbe/cache.mjs BASELINE CANDIDATE [OUTPUT] [PAIRS]');
const hash = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const families = process.argv.includes('--edit-only') ? [] :
  ['text', 'decimal', 'record', 'json', 'table'];
const compilers = { baseline, candidate };
const samples = [];
mkdirSync(output, { recursive: true });
const declaration = {
  format: 'foo.qbe-build-latency.v1', date: new Date().toISOString(),
  target: process.platform === 'win32' ? 'windows-x64' : 'linux-x64',
  mode: 'release', backend: 'qbe', pairs, warmups: 3,
  cpu: cpus()[0]?.model, cores: cpus().length, memoryBytes: totalmem(),
  os: `${process.platform} ${release()}`, node: process.version,
  compilers: Object.fromEntries(Object.entries(compilers).map(([name, path]) =>
    [name, { path, sha256: hash(path) }])),
  command: 'build main.iv --backend qbe --mode release --target TARGET --compact',
};
writeFileSync(join(output, 'declaration.json'), JSON.stringify(declaration, null, 2) + '\n');

function compile(family, variant, pair, warmup = false) {
  const cwd = join(output, family, variant);
  const start = performance.now();
  const run = spawnSync(compilers[variant], ['build', 'main.iv', '--backend', 'qbe',
    '--mode', 'release', '--target', declaration.target, '--compact'],
    { cwd, encoding: 'utf8', timeout: 180000 });
  const sample = { family, variant, pair, warmup,
    milliseconds: performance.now() - start, exit: run.status,
    stdout: run.stdout, stderr: run.stderr };
  samples.push(sample);
  writeFileSync(join(output, 'samples.json'), JSON.stringify(samples, null, 2) + '\n');
  if (run.status !== 0) throw Error(`${family}/${variant}/${pair}: ${run.stdout}\n${run.stderr}`);
  return sample;
}

for (const family of families) {
  const source = join(root, 'benchmark', 'features', `${family}.iv`);
  for (const variant of Object.keys(compilers)) {
    const destination = join(output, family, variant, 'main.iv');
    mkdirSync(dirname(destination), { recursive: true });
    cpSync(source, destination);
    compile(family, variant, -1, true);
    const executable = join(output, family, variant, 'output',
      process.platform === 'win32' ? 'app.exe' : 'app');
    const run = spawnSync(executable, [], { encoding: 'utf8', timeout: 30000 });
    if (run.status !== 0) throw Error(`${family}/${variant} output failed: ${run.stderr}`);
    declaration[`${family}:${variant}`] = {
      sourceSha256: hash(source), executableSha256: hash(executable),
      stdoutSha256: createHash('sha256').update(run.stdout).digest('hex'),
    };
  }
}
for (let warmup = 0; warmup < 3; warmup++)
  for (const family of families)
    for (const variant of warmup % 2 ? ['candidate', 'baseline'] : ['baseline', 'candidate'])
      compile(family, variant, -2 - warmup, true);
for (let pair = 0; pair < pairs; pair++) {
  for (const family of families)
    for (const variant of pair % 2 ? ['candidate', 'baseline'] : ['baseline', 'candidate']) {
      const sample = compile(family, variant, pair);
      console.log(`${family}/${variant}/${pair}: ${sample.milliseconds.toFixed(1)} ms`);
    }
}
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const summary = Object.fromEntries(families.map(family => {
  const values = variant => samples.filter(item => item.family === family &&
    item.variant === variant && !item.warmup).map(item => item.milliseconds);
  const old = values('baseline');
  const fresh = values('candidate');
  const paired = old.map((ms, index) => ms - fresh[index]);
  return [family, { baselineMedianMs: median(old), candidateMedianMs: median(fresh),
    pairedMedianSavingMs: median(paired), candidateWins: paired.filter(ms => ms > 0).length,
    baselineRangeMs: [Math.min(...old), Math.max(...old)],
    candidateRangeMs: [Math.min(...fresh), Math.max(...fresh)] }];
}));
const edit = {};
for (const variant of Object.keys(compilers)) {
  const cwd = join(output, 'edit', variant);
  mkdirSync(cwd, { recursive: true });
  writeFileSync(join(cwd, 'main.iv'),
    'use testing as check.\nstart { check.number(0, 0). }\n');
  compile('edit', variant, -1, true);
}
for (let warmup = 0; warmup < 3; warmup++)
  for (const variant of warmup % 2 ? ['candidate', 'baseline'] : ['baseline', 'candidate']) {
    const cwd = join(output, 'edit', variant);
    const value = warmup + 1;
    writeFileSync(join(cwd, 'main.iv'),
      `use testing as check.\nstart { check.number(${value}, ${value}). }\n`);
    compile('edit', variant, -2 - warmup, true);
  }
for (let pair = 0; pair < pairs; pair++) {
  for (const variant of pair % 2 ? ['candidate', 'baseline'] : ['baseline', 'candidate']) {
    const cwd = join(output, 'edit', variant);
    const value = pair + 4;
    const source = `use testing as check.\nstart { check.number(${value}, ${value}). }\n`;
    writeFileSync(join(cwd, 'main.iv'), source);
    const sample = compile('edit', variant, pair);
    const executable = join(cwd, 'output', process.platform === 'win32' ? 'app.exe' : 'app');
    const run = spawnSync(executable, [], { encoding: 'utf8', timeout: 30000 });
    if (run.status !== 0) throw Error(`edit/${variant}/${pair} output failed: ${run.stderr}`);
    console.log(`edit/${variant}/${pair}: ${sample.milliseconds.toFixed(1)} ms`);
  }
}
const edited = variant => samples.filter(item => item.family === 'edit' &&
  item.variant === variant && !item.warmup).map(item => item.milliseconds);
const oldEdit = edited('baseline');
const newEdit = edited('candidate');
const editSavings = oldEdit.map((ms, index) => ms - newEdit[index]);
edit.summary = { baselineMedianMs: median(oldEdit), candidateMedianMs: median(newEdit),
  pairedMedianSavingMs: median(editSavings), candidateWins: editSavings.filter(ms => ms > 0).length,
  baselineRangeMs: [Math.min(...oldEdit), Math.max(...oldEdit)],
  candidateRangeMs: [Math.min(...newEdit), Math.max(...newEdit)] };
writeFileSync(join(output, 'report.json'), JSON.stringify({ ...declaration, summary, edit }, null, 2) + '\n');
console.log(`Report: ${join(output, 'report.json')}`);
