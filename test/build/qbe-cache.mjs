import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync, appendFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import assert from 'node:assert/strict';

const compiler = resolve(process.env.FOO_COMPILER || '');
if (!process.env.FOO_COMPILER) throw Error('Set FOO_COMPILER to a packaged QBE compiler');
const root = mkdtempSync(join(tmpdir(), 'foo-qbe-cache-'));
const source = join(root, 'main.iv');
const manifest = join(root, 'project.ivc');
const artifact = join(root, '.artifacts', 'build', process.platform === 'win32' ? 'app.exe' : 'app');
const runtime = join(root, '.artifacts', 'build', process.platform === 'win32' ? 'qbe-runtime.obj' : 'qbe-runtime.o');
const assembly = join(root, '.artifacts', 'build', process.platform === 'win32' ? 'main-win.s' : 'main-linux.s');
const object = join(root, '.artifacts', 'build', process.platform === 'win32' ? 'main.obj' : 'main.o');
const output = join(root, 'output', process.platform === 'win32' ? 'app.exe' : 'app');
const receipt = join(root, '.artifacts', 'build', 'build.json');
const sha = data => createHash('sha256').update(data).digest('hex');
const build = (mode = 'dev') => {
  const run = spawnSync(compiler, ['build', 'main.iv', '--backend', 'qbe',
    '--mode', mode, '--target', process.platform === 'win32' ? 'windows-x64' : 'linux-x64',
    '--compact'], { cwd: root, encoding: 'utf8', timeout: 120000 });
  assert.equal(run.status, 0, run.stdout + run.stderr);
  assert.match(run.stderr, /100%/, 'successful build progress must finish at 100%');
  return JSON.parse(readFileSync(receipt, 'utf8'));
};
try {
  writeFileSync(source, 'use testing as check.\nstart { check.number(1, 1). }\n');
  const first = build();
  assert.equal(first.version, 1);
  const original = sha(readFileSync(artifact));
  const unchanged = statSync(artifact).mtimeMs;
  const runtimeTime = statSync(runtime).mtimeMs;
  const hit = build();
  assert.equal(hit.key, first.key);
  assert.equal(statSync(artifact).mtimeMs, unchanged);

  const before = statSync(source);
  writeFileSync(source, 'use testing as check.\nstart { check.number(2, 2). }\n');
  utimesSync(source, before.atime, before.mtime);
  const edited = build();
  assert.notEqual(edited.inputs.find(item => item.path.endsWith('main.iv')).sha256,
    first.inputs.find(item => item.path.endsWith('main.iv')).sha256);
  assert.notEqual(sha(readFileSync(artifact)), original);
  assert.equal(statSync(runtime).mtimeMs, runtimeTime);
  assert.ok(readFileSync(assembly + '.cache.json', 'utf8').includes('outputs'));
  assert.ok(readFileSync(object + '.cache.json', 'utf8').includes('outputs'));
  const executed = spawnSync(output, [], { encoding: 'utf8' });
  assert.equal(executed.status, 0, executed.stderr);

  const assemblyTime = statSync(assembly).mtimeMs;
  const objectTime = statSync(object).mtimeMs;
  const correct = sha(readFileSync(artifact));
  appendFileSync(artifact, 'damaged');
  build();
  assert.equal(sha(readFileSync(artifact)), correct);
  assert.equal(statSync(assembly).mtimeMs, assemblyTime);
  assert.equal(statSync(object).mtimeMs, objectTime);

  writeFileSync(join(root, 'extra.iv'), 'public constant extra is 2.\n');
  const added = build();
  assert.notEqual(added.sources, edited.sources);

  appendFileSync(output, 'damaged');
  build();
  assert.equal(sha(readFileSync(output)), sha(readFileSync(artifact)));

  const release = build('release');
  assert.notEqual(release.key, added.key);
  assert.equal(spawnSync(output, [], { encoding: 'utf8' }).status, 0);

  writeFileSync(manifest, 'capability "project"\nproject { name is "cache" version is "0.1.0" build { output is "dist" } }\n');
  const changed = build();
  assert.equal(changed.published, join(root, 'dist', process.platform === 'win32' ? 'app.exe' : 'app'));
  assert.ok(readdirSync(join(root, 'dist')).length > 0);
  console.log('QBE build receipt invalidation: ok');
} finally {
  rmSync(root, { recursive: true, force: true });
}
