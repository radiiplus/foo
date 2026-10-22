import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { run as build } from '../../tools/worker.mjs';

if (!process.env.FOO_COMPILER) throw Error('Set FOO_COMPILER to a packaged QBE compiler');
const compiler = resolve(process.env.FOO_COMPILER);
const root = mkdtempSync(join(tmpdir(), 'foo-qbe-worker-'));
const source = join(root, 'main.iv');
const receipt = join(root, '.artifacts', 'build', 'build.json');
const output = join(root, 'output', process.platform === 'win32' ? 'app.exe' : 'app');
const sha = content => createHash('sha256').update(content).digest('hex');
const recorded = () => {
  try {
    const data = JSON.parse(readFileSync(receipt, 'utf8'));
    return data.inputs.find(input => input.path.endsWith('main.iv'))?.sha256;
  } catch { return ''; }
};
try {
  writeFileSync(source, 'use testing as check.\nstart { check.number(1, 1). }\n');
  const code = await build(compiler, ['build', 'main.iv', '--backend', 'qbe',
    '--mode', 'dev', '--target', process.platform === 'win32' ? 'windows-x64' : 'linux-x64',
    '--compact'], root);
  assert.equal(code, 0);
  const original = recorded();
  assert.equal(original, sha(readFileSync(source)));
  writeFileSync(source, 'use testing as check.\nstart { check.number(2, 2). }\n');
  await new Promise(done => setTimeout(done, 700));
  writeFileSync(source, 'use testing as check.\nstart { check.number(3, 3). }\n');
  const expected = sha(readFileSync(source));
  const deadline = Date.now() + 20000;
  while (recorded() !== expected && Date.now() < deadline)
    await new Promise(done => setTimeout(done, 100));
  assert.equal(recorded(), expected, 'worker did not prewarm the edited script');
  const run = spawnSync(output, [], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  console.log('QBE standalone worker prewarm: ok');
} finally {
  rmSync(root, { recursive: true, force: true });
}
