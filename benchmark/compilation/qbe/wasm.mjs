import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { cpus, release, totalmem } from 'node:os';
import { dirname, join, resolve } from 'node:path';

if (process.argv.length < 4) throw Error('Usage: node benchmark/compilation/qbe/wasm.mjs COMPILER OUTPUT');
const root = resolve(import.meta.dirname, '..', '..', '..');
const compiler = resolve(process.argv[2]);
const output = resolve(process.argv[3]);
const fixture = join(root, 'test', 'backend', 'qbe', 'fixtures', 'project', 'wasi');
const source = join(output, 'src', 'main.iv');
const sha256 = path => createHash('sha256').update(readFileSync(path)).digest('hex');
mkdirSync(dirname(source), { recursive: true });
cpSync(join(fixture, 'project.ivc'), join(output, 'project.ivc'));
const original = readFileSync(join(fixture, 'src', 'main.iv'), 'utf8');
const samples = [];
for (let index = 0; index < 5; index++) {
  writeFileSync(source, original.replace('descend(42, 3)', `descend(42, ${index + 3})`));
  const start = performance.now();
  const built = spawnSync(compiler, ['build', '--backend', 'qbe', '--mode', 'release',
    '--target', 'wasi', '--compact'], { cwd: output,
    env: { ...process.env, FOO_BUILD_PROFILE: '1' },
    encoding: 'utf8', timeout: 180000 });
  const sample = { index, milliseconds: performance.now() - start,
    exit: built.status, stdout: built.stdout, stderr: built.stderr };
  samples.push(sample);
  writeFileSync(join(output, 'samples.json'), JSON.stringify(samples, null, 2) + '\n');
  if (built.status !== 0) throw Error(`WASI ${index}: ${built.stdout}\n${built.stderr}`);
  const artifact = join(output, 'output', 'app.wasm');
  sample.artifactSha256 = sha256(artifact);
  if (index > 0 && sample.artifactSha256 === samples[index - 1].artifactSha256)
    throw Error(`WASI ${index} did not change the module`);
  const checked = spawnSync(process.execPath, [join(fixture, 'check.mjs'), artifact],
    { encoding: 'utf8', timeout: 30000 });
  if (checked.status !== 0) throw Error(`WASI ${index} failed: ${checked.stderr}`);
  console.log(`WASI ${index}: ${sample.milliseconds.toFixed(1)} ms\n${built.stderr}`);
}
writeFileSync(join(output, 'report.json'), JSON.stringify({
  format: 'foo.qbe-wasm-profile.v1', target: 'wasi', mode: 'release',
  compiler: { path: compiler, sha256: sha256(compiler) },
  cpu: cpus()[0]?.model, cores: cpus().length, memoryBytes: totalmem(),
  os: `${process.platform} ${release()}`, node: process.version, samples,
}, null, 2) + '\n');
