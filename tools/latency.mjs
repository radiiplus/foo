import { value } from './arguments.mjs';
import { median } from './statistics.mjs';
// Paired release compiler builds, with isolated inputs and always executed output.
import { spawn } from 'node:child_process';
import { cpSync as copy, mkdirSync as mkdir, readFileSync as read, readdirSync as entries, writeFileSync as write } from 'node:fs';
import { createHash as hasher } from 'node:crypto';
import { join, resolve } from 'node:path';
import { cpus } from 'node:os';

const root = resolve(import.meta.dirname, '..');
const pairs = Number((value('--pairs') || '3'));
if (!Number.isInteger(pairs) || pairs < 2 || pairs > 20) throw Error('--pairs must be 2..20');
const output = resolve((value('--output') || join(root, '.artifacts/native-benchmark', `run-${process.pid}-${Date.now()}`)));
const snapshot = join(output, 'source');
mkdir(snapshot, { recursive: true });
for (const file of ['src', 'assets', 'installers/assets', 'installers/windows/foo.rc',
  'package.json', 'project.ivc', 'toolchain.json', 'toolchain/assets.json', 'tools/native.mjs', 'tools/inputs.mjs', 'tools/arguments.mjs', 'tools/nim.mjs', 'tools/tree.mjs'])
  copy(join(root, file), join(snapshot, file), { recursive: true });
const identity = hasher('sha256');
for (const entry of entries(snapshot, { recursive: true, withFileTypes: true })
  .filter(entry => entry.isFile()).sort((a, b) => join(a.parentPath, a.name).localeCompare(join(b.parentPath, b.name)))) {
  const file = join(entry.parentPath, entry.name);
  identity.update(file.slice(snapshot.length + 1).replaceAll('\\', '/')).update('\0').update(read(file)).update('\0');
}
const declaration = { format: 'foo.native-benchmark.v1', pairs, platform: process.platform,
  arch: process.arch, cpu: cpus()[0]?.model, node: process.version, sourceIdentity: identity.digest('hex'),
  memoryManager: 'refc', workers: 2, comparison: 'Previous forced-C rebuild vs affected-module rebuild after an embedded SVG edit',
  measured: ['clean compiler build', 'embedded-input incremental compiler build', 'compiler version startup'],
  note: 'This measures compiler construction, excluding vendor audit, release staging, installers and signing.' };
write(join(output, 'declaration.json'), JSON.stringify(declaration, null, 2) + '\n');
async function run(command, args, log) {
  const started = performance.now();
  const result = await new Promise((done, reject) => {
    const child = spawn(command, args, { cwd: snapshot, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.on('error', reject);
    child.on('close', code => done({ code, stdout, stderr }));
  });
  write(join(output, log + '.log'), result.stdout + result.stderr);
  if (result.code !== 0) throw Error(`${log} failed; see ${join(output, log + '.log')}`);
  return { ms: performance.now() - started, compiledC: (result.stderr.match(/^CC:/gm) || []).length, ...result };
}
const samples = [];
const svg = read(join(snapshot, 'assets/dark.svg'), 'utf8');
const version = JSON.parse(read(join(snapshot, 'package.json'))).version;
const executable = process.platform === 'win32' ? 'foo.exe' : 'foo';
async function sample(variant, pair, marker = '') {
  const cache = join(output, variant, 'cache');
  const binary = join(output, variant, executable);
  if (marker) write(join(snapshot, 'assets/dark.svg'), svg + `\n<!-- ${marker} -->\n`);
  const result = await run(process.execPath, [join(snapshot, 'tools/native.mjs'), '--mm', 'refc', '--jobs', '2',
    '--cache', cache, '--output', binary, ...(variant === 'forced' ? ['--rebuild'] : [])], `${variant}-${pair}-compile`);
  if (marker && !read(binary).includes(Buffer.from(marker))) throw Error('Executable reused stale embedded SVG input');
  const startup = await run(binary, ['version'], `${variant}-${pair}-startup`);
  if (!startup.stdout.includes(`compiler ${version}`)) throw Error('Produced compiler did not execute the expected version');
  samples.push({ variant, pair, compileMs: result.ms, compiledC: result.compiledC, startupMs: startup.ms, marker });
  write(join(output, 'samples.json'), JSON.stringify(samples, null, 2) + '\n');
  console.log(`${variant}/${pair}: ${Math.round(result.ms)} ms, ${result.compiledC} C files; startup ${Math.round(startup.ms)} ms`);
}
for (const variant of ['forced', 'incremental']) await sample(variant, -1);
for (let pair = 0; pair < pairs; pair++) {
  for (const variant of pair % 2 ? ['incremental', 'forced'] : ['forced', 'incremental'])
    await sample(variant, pair, `foo-native-benchmark-${pair}-${variant}`);
}
const changes = Array.from({ length: pairs }, (unused, pair) => {
  const forced = samples.find(sample => sample.variant === 'forced' && sample.pair === pair);
  const incremental = samples.find(sample => sample.variant === 'incremental' && sample.pair === pair);
  return { pair, forcedMs: forced.compileMs, incrementalMs: incremental.compileMs,
    changePercent: (incremental.compileMs / forced.compileMs - 1) * 100 };
});
const change = median(changes.map(change => change.changePercent));
write(join(output, 'report.json'), JSON.stringify({ ...declaration, complete: true, samples, changes, medianChangePercent: change }, null, 2) + '\n');
console.log(`Paired embedded-edit median: ${change.toFixed(1)}%; report ${join(output, 'report.json')}`);
