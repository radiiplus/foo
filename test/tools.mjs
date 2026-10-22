import assert from 'node:assert/strict';
import { mkdirSync as mkdir, readFileSync as read, rmSync as remove, writeFileSync as write, existsSync as exists } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { spawnSync as invoke } from 'node:child_process';
import { value, option } from '../tools/arguments.mjs';
import { find } from '../tools/nim.mjs';
import { files } from '../tools/tree.mjs';
import { median, summary } from '../tools/statistics.mjs';
import * as artifacts from '../tools/artifacts.mjs';
import { environment as testEnvironment, output as testDirectory, temporary as testOutput } from './location.mjs';
import { checked, linux, run, session as begin } from '../tools/wsl.mjs';
import { auditWsl } from './support/wsl.mjs';

const root = resolve(import.meta.dirname, '..');
assert.equal(value('--output', []), '');
assert.equal(option('--output', []), '');
for (const args of [['--output', 'a b'], ['--output=a b']]) {
  assert.equal(value('--output', args), 'a b');
  assert.equal(option('--output', args), resolve('a b'));
}
for (const args of [['--output'], ['--output='], ['--output', '--target'], ['--output=--target']])
  assert.throws(() => value('--output', args), /requires a value/);
assert.equal(value('--count', ['--count', '-1']), '-1');
assert.equal(median([6, 1, 3, 2]), 2.5);
assert.equal(median([6, 1, 3, 2], true), 3);
assert.equal(median([6, 1, 3]), 3);
assert.throws(() => median([]));
assert.throws(() => median([NaN]));
assert.deepEqual(summary([3, 1, 2]).samplesMs, [3, 1, 2]);
assert.equal(summary([3, 1, 2]).meanMs, 2);
assert.equal(auditWsl().directCallers, 5);

const folder = testOutput();
try {
  const previousTestDir = process.env.FOO_TEST_ARTIFACT_DIR;
  process.env.FOO_TEST_ARTIFACT_DIR = join(folder, 'selected');
  try {
    assert.equal(testDirectory(), join(folder, 'selected'));
    const run = testOutput();
    assert(run.startsWith(join(folder, 'selected', 'run-')));
    const scoped = testEnvironment(run);
    assert.equal(scoped.FOO_TEST_ARTIFACT_DIR, run);
    assert.equal(scoped.TEMP, join(run, 'temp'));
    assert(exists(scoped.TEMP));
  } finally {
    if (previousTestDir === undefined) delete process.env.FOO_TEST_ARTIFACT_DIR;
    else process.env.FOO_TEST_ARTIFACT_DIR = previousTestDir;
  }
  for (const name of ['src', 'test', 'tools', 'bin']) mkdir(join(folder, name));
  write(join(folder, 'tools', 'probe.mjs'), 'spawnSync("wsl' + '.exe", ["--", "true"]);');
  assert.throws(() => auditWsl(folder), /Unreviewed direct WSL caller/);
  const previous = process.env.FOO_ARTIFACT_ROOT;
  process.env.FOO_ARTIFACT_ROOT = join(folder, 'artifacts');
  try {
    assert.equal(artifacts.path('test', 'result'), join(folder, 'artifacts', 'test', 'result'));
    assert.throws(() => artifacts.path('..'), /simple names/);
    const owned = artifacts.create('test');
    const manifest = join(owned, 'manifest.json');
    assert.equal(artifacts.clean({ dryRun: true }).candidates.length, 0);
    const record = JSON.parse(read(manifest, 'utf8'));
    record.pid = 99999999;
    write(manifest, JSON.stringify(record));
    assert.equal(artifacts.clean({ dryRun: true }).candidates.length, 1);
    assert(exists(owned));
    assert.equal(artifacts.clean({ all: true }).candidates.length, 1);
    assert(!exists(owned));
  } finally {
    if (previous === undefined) delete process.env.FOO_ARTIFACT_ROOT;
    else process.env.FOO_ARTIFACT_ROOT = previous;
  }
  const [first, second] = checked([
    { command: 'node', args: ['-p', 'process.ppid'] },
    { command: 'node', args: ['-p', 'process.ppid'] },
  ]);
  assert.match(first.stdout.trim(), /^\d+$/);
  assert.equal(first.stdout.trim(), second.stdout.trim());
  assert.match(linux(root), process.platform === 'win32' ? /^\/mnt\/[a-z]\// : /^\//);
  assert.throws(() => checked([{ command: 'foo-tool-that-does-not-exist', args: [] }]),
    /Required WSL tool is missing/);
  assert.throws(() => run([{ command: 'node', args: [], env: { PATH: '/tmp' } }]),
    /unapproved environment/);
  const session = await begin();
  const priorSocket = process.env.FOO_WSL_SOCKET;
  process.env.FOO_WSL_SOCKET = session.socket;
  try {
    const firstSession = checked([{ command: 'node', args: ['-p', 'process.ppid'] }])[0];
    const secondSession = checked([{ command: 'node', args: ['-p', 'process.ppid'] }])[0];
    assert.equal(firstSession.stdout.trim(), secondSession.stdout.trim());
  } finally {
    if (priorSocket === undefined) delete process.env.FOO_WSL_SOCKET;
    else process.env.FOO_WSL_SOCKET = priorSocket;
    await session.close();
  }
  const executable = process.platform === 'win32' ? 'nim.exe' : 'nim';
  const compiler = join(folder, '.choosenim/toolchains/nim-2.2.12/bin', executable);
  mkdir(dirname(compiler), { recursive: true });
  write(compiler, 'discovery does not execute tools');
  assert.equal(find({ environment: {}, profile: folder }), compiler);
  assert.equal(find({ environment: { NIM_BIN: process.execPath }, profile: folder }), process.execPath);
  remove(join(folder, '.choosenim'), { recursive: true });
  assert.equal(find({ environment: {}, profile: folder }), executable);
  for (const file of ['src/z.nim', 'src/a.nim', 'src/.artifacts/deep/bad.nim', 'src/.foo/bad.nim', 'src/node_modules/bad.nim']) {
    mkdir(dirname(join(folder, file)), { recursive: true });
    write(join(folder, file), '');
  }
  assert.deepEqual(files(join(folder, 'src'), '.nim'), [join(folder, 'src/a.nim'), join(folder, 'src/z.nim')]);
} finally { remove(folder, { recursive: true, force: true }); }

// Parse every owned JavaScript module, resolve every relative import, and catch
// omitted shared tooling in the npm distribution without executing bootstraps.
const modules = ['tools', 'test', 'bin', 'benchmark']
  .flatMap(directory => files(join(root, directory), '.mjs'));
for (const file of modules) {
  const result = invoke(process.execPath, ['--check', file], { encoding: 'utf8', windowsHide: true });
  assert.equal(result.status, 0, `${file}\n${result.stderr}`);
  for (const match of read(file, 'utf8').matchAll(/(?:from\s+|import\s*\(\s*)['"](\.[^'"]+)['"]/g))
    assert(exists(resolve(dirname(file), match[1])), `Missing relative import in ${file}: ${match[1]}`);
}
const manifest = JSON.parse(read(join(root, 'package.json')));
assert(manifest.files.includes('tools/'));
assert(manifest.files.includes('toolchain/'));
for (const output of [root, join(root, 'src', 'release'), join(root, '.artifacts', 'release-native')]) {
  const rejected = invoke(process.execPath, [join(root, 'tools/build.mjs'), '--isolated', '--output', output],
    { cwd: root, encoding: 'utf8', windowsHide: true });
  assert.notEqual(rejected.status, 0, `Unsafe release output was accepted: ${output}`);
  assert.match(rejected.stderr, /Release output must/, output);
}
console.log(`Shared tooling and import gates passed: ${modules.length} JavaScript modules`);
