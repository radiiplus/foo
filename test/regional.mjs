import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { temporary } from './location.mjs';
import { catalog, impact, regions, root, selection } from './regions.mjs';
import { plan } from './native/plan.mjs';
import { matrixEvidence, nativeEvidence, summarize } from './run.mjs';

const items = catalog();
const original = plan(root, { noBatching: true }).units.map(unit => `test/${unit.name}`);
assert.deepEqual(items.native.map(item => item.id), original);
assert.equal(new Set(items.native.map(item => item.id)).size, original.length);
assert.equal(items.fixtures.length > 0, true);
assert.deepEqual(selection(['core']).selected.filter(item => item.kind === 'matrix')
  .map(item => item.id), items.fixtures.flatMap(path => [`${path}@dev`, `${path}@release`]));

const all = regions.order.flatMap(region => selection([region]).selected);
const native = new Set(all.filter(item => item.kind === 'native').map(item => item.id));
assert.deepEqual([...native].sort(), [...original].sort());
for (const [id, region] of [
  ['test/ast/formatter.nim', 'core'],
  ['test/backend/qbe/wasm.nim', 'targets'],
  ['test/cli/benchmark.nim', 'bench'],
  ['test/editor/lsp.nim', 'editor'],
  ['test/runtime/copy.nim', 'runtime'],
]) assert.equal(items.native.find(item => item.id === id)?.region, region, id);
for (const id of ['test/editor/lsp.mjs', 'test/runtime/tcp.mjs'])
  assert(items.scripts.some(item => item.id === id), `${id} missing script route`);
for (const region of regions.order) {
  const selected = selection([region]);
  assert.deepEqual(selected.regions, [region]);
  assert(selected.selected.every(item => item.region === region));
}
assert(!selection(['net']).selected.some(item => item.id === 'test/library/check.mjs'));
assert(!selection(['bench']).selected.some(item => item.id === 'test/native/speed.mjs'));
assert(!selection(['core'], { mode: 'dev' }).selected.some(item => item.id.endsWith('@release')));

for (const [file, expected] of [
  ['src/lex/token.nim', regions.order],
  ['src/backend/qbe/abi.nim', regions.order],
  ['src/runtime/wide.c', regions.order],
  ['src/runtime/provider/service.h', regions.order],
  ['src/runtime/cpu/arch.h', regions.order],
  ['src/opt/substrate.nim', regions.order],
  ['toolchain/assets.json', regions.order],
  ['lib/net.iv', ['core', 'net', 'release']],
  ['test/library/tls.iv', ['core', 'net', 'release']],
  ['src/runtime/files/handles.c', ['core', 'runtime', 'targets', 'packages', 'release']],
]) {
  const affected = impact([file], items);
  for (const region of expected)
    assert(affected.has(region), `${file} missed ${region}`);
}
assert.throws(() => selection(['changed'], { files: [] }), /No changed files/);
assert.deepEqual([...impact(['test/library/algorithms.iv'], items).keys()], ['core']);
assert.deepEqual([...impact(['test/lex/lexer.nim'], items).keys()], ['core']);
const netRegions = ['core', 'net', 'runtime', 'targets', 'packages', 'release'];
assert.deepEqual([...impact(['lib/net.iv'], items).keys()].sort(), [...netRegions].sort());
const releaseDependencies = regions.regions.release.depends;
try {
  regions.regions.release.depends = ['net'];
  assert.notDeepEqual([...impact(['lib/net.iv'], items).keys()].sort(), [...netRegions].sort());
} finally {
  regions.regions.release.depends = releaseDependencies;
}

const leaf = { id: 'test/lex/lexer.nim', region: 'core', kind: 'native', reason: 'test' };
const result = { modules: ['lex/lexer.nim'], completedModules: [], executedModules: 1,
  executed: true, passed: true, moduleCountExact: true };
const nativeReport = { complete: true, passed: true, expectedSuites: 1,
  observedSuites: 1, results: [result] };
assert.equal(nativeEvidence([leaf], nativeReport, 0)[0].status, 'passed');
assert.equal(nativeEvidence([leaf], null, 0)[0].status, 'failed');
assert.equal(nativeEvidence([leaf], nativeReport, 1)[0].status, 'failed');
assert.equal(nativeEvidence([leaf], { ...nativeReport, passed: false }, null)[0].status, 'failed');
assert.equal(nativeEvidence([leaf], { ...nativeReport, results: [] }, 0)[0].status, 'failed');

const fixture = { id: 'test/library/algorithms.iv@dev', region: 'core',
  kind: 'matrix', reason: 'test' };
const row = { file: 'test/library/algorithms.iv', mode: 'dev', expectedTests: 2,
  executedTests: 2, passed: true, errors: [] };
const matrixReport = { complete: true, passed: true, inventoryUnchanged: true, rows: [row] };
assert.equal(matrixEvidence([fixture], matrixReport, 0)[0].status, 'passed');
assert.equal(matrixEvidence([fixture], { ...matrixReport, rows: [] }, 0)[0].status, 'failed');
assert.equal(matrixEvidence([fixture], { ...matrixReport, passed: false }, null)[0].status, 'failed');
assert.equal(matrixEvidence([fixture], { ...matrixReport,
  rows: [{ ...row, executedTests: 1 }] }, 0)[0].status, 'failed');

assert.equal(summarize([], []).successful, false);
assert.equal(summarize([leaf], [{ ...leaf, status: 'unsupported', executed: false }]).successful, false);
assert.equal(summarize([leaf], [{ ...leaf, status: 'passed', executed: true }]).successful, true);
const scratch = temporary();
try {
  const driver = join(scratch, 'empty.mjs');
  const output = join(scratch, 'regional');
  writeFileSync(driver, 'process.exit(0)\n');
  const stale = join(output, 'core', 'matrix');
  mkdirSync(stale, { recursive: true });
  writeFileSync(join(stale, 'report.json'), JSON.stringify({ complete: true, passed: true,
    rows: [{ file: 'test/library/algorithms.iv', mode: 'dev', expectedTests: 2,
      executedTests: 2, passed: true }] }));
  const injected = spawnSync(process.execPath, ['test/run.mjs', 'core',
    '--only', 'test/library/algorithms.iv@dev', '--output', output], {
    cwd: root, env: { ...process.env, FOO_TEST_DRIVER: driver }, encoding: 'utf8',
    windowsHide: true, timeout: 60000,
  });
  assert.equal(injected.status, 1, injected.stderr || injected.error?.message);
  const report = JSON.parse(readFileSync(join(output, 'report.json'), 'utf8'));
  assert.equal(report.selected, 1);
  assert.equal(report.executed, 0);
  assert.equal(report.failed, 1);
  assert.equal(report.passed, false);
  assert.equal(report.cases[0].id, 'test/library/algorithms.iv@dev');
  assert.notEqual(report.jobRoot, stale);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
if (process.argv.includes('--integration')) {
  const run = temporary();
  const readReport = path => JSON.parse(readFileSync(path, 'utf8'));
  const digest = path => createHash('sha256').update(readFileSync(join(root, path))).digest('hex');
  const sources = ['test/lex/lexer.nim', 'test/library/layout.iv'];
  const before = sources.map(digest);
  const execute = (args, label) => {
    const child = spawnSync(process.execPath, args, { cwd: root, encoding: 'utf8',
      windowsHide: true, timeout: 3600000, maxBuffer: 16 * 1024 * 1024 });
    assert.equal(child.status, 0, `${label}: ${child.error?.message || child.stderr || child.stdout}`);
  };
  try {
    const oldNative = join(run, 'old-native');
    const newNative = join(run, 'new-native');
    execute(['test/native/run.mjs', '--filter=lex/lexer.nim', '--no-batching',
      `--output=${oldNative}`], 'old native');
    execute(['test/run.mjs', 'core', '--only', 'test/lex/lexer.nim',
      '--output', newNative], 'regional native');
    const nativeOld = readReport(join(oldNative, 'summary.json'));
    const nativeNew = readReport(join(newNative, 'report.json'));
    assert.equal(nativeOld.passed, true);
    assert.equal(nativeNew.passed, true);
    assert.deepEqual(nativeNew.cases.map(item => item.id),
      nativeOld.results.flatMap(item => item.modules.map(id => `test/${id}`)));
    assert.equal(nativeNew.executed, nativeOld.executedModules);

    const oldMatrix = join(run, 'old-matrix');
    const newMatrix = join(run, 'new-matrix');
    execute(['test/matrix.mjs', '--filter', 'layout.iv', '--modes', 'dev',
      '--output', oldMatrix], 'old matrix');
    execute(['test/run.mjs', 'core', '--only', 'test/library/layout.iv@dev',
      '--output', newMatrix], 'regional matrix');
    const matrixOld = readReport(join(oldMatrix, 'report.json'));
    const matrixNew = readReport(join(newMatrix, 'report.json'));
    assert.equal(matrixOld.passed, true);
    assert.equal(matrixNew.passed, true);
    assert.deepEqual(matrixNew.cases.map(item => item.id),
      matrixOld.rows.map(item => `${item.file}@${item.mode}`));
    assert.equal(matrixNew.cases[0].expectedTests, matrixOld.rows[0].expectedTests);
    assert.equal(matrixNew.cases[0].executedTests, matrixOld.rows[0].executedTests);
    assert.deepEqual(sources.map(digest), before, 'Sources changed during runner comparison');
    console.log('Old and regional runners executed identical native and semantic leaves.');
  } finally {
    console.log(`Regional comparison evidence: ${run}`);
  }
}
console.log(`Regional routing: ${original.length} native leaves, ${items.fixtures.length} semantic fixtures, ${items.scripts.length} script entries; impact and failure injection passed.`);
