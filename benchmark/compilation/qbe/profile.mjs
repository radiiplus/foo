import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { cpus, release, totalmem } from 'node:os';
import { join, resolve } from 'node:path';

if (process.argv.length < 4) throw Error('Usage: node benchmark/compilation/qbe/profile.mjs COMPILER OUTPUT');
const compiler = resolve(process.argv[2]);
const output = resolve(process.argv[3]);
const target = process.platform === 'win32' ? 'windows-x64' : 'linux-x64';
const sha256 = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const samples = [];
mkdirSync(output, { recursive: true });
for (let index = 0; index < 5; index++) {
  const value = index + 1;
  writeFileSync(join(output, 'main.iv'),
    `use testing as check.\nstart { check.number(${value}, ${value}). }\n`);
  const start = performance.now();
  const built = spawnSync(compiler, ['build', 'main.iv', '--backend', 'qbe',
    '--mode', 'release', '--target', target, '--compact'], {
    cwd: output, env: { ...process.env, FOO_BUILD_PROFILE: '1' },
    encoding: 'utf8', timeout: 180000,
  });
  const sample = { index, milliseconds: performance.now() - start,
    exit: built.status, stdout: built.stdout, stderr: built.stderr };
  samples.push(sample);
  writeFileSync(join(output, 'samples.json'), JSON.stringify(samples, null, 2) + '\n');
  if (built.status !== 0) throw Error(`build ${index}: ${built.stdout}\n${built.stderr}`);
  const artifact = join(output, 'output', process.platform === 'win32' ? 'app.exe' : 'app');
  const run = spawnSync(artifact, [], { encoding: 'utf8', timeout: 30000 });
  if (run.status !== 0) throw Error(`output ${index}: ${run.stderr}`);
  sample.artifactSha256 = sha256(artifact);
  console.log(`edit ${index}: ${sample.milliseconds.toFixed(1)} ms\n${built.stderr}`);
}
writeFileSync(join(output, 'report.json'), JSON.stringify({
  format: 'foo.qbe-build-profile.v1', target, mode: 'release',
  compiler: { path: compiler, sha256: sha256(compiler) },
  cpu: cpus()[0]?.model, cores: cpus().length, memoryBytes: totalmem(),
  os: `${process.platform} ${release()}`, node: process.version, samples,
}, null, 2) + '\n');
