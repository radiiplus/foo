import { find } from '../../tools/nim.mjs';
import assert from 'node:assert/strict';
import { cpSync as copy, mkdirSync as mkdir, readFileSync as read, rmSync as remove, writeFileSync as write } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync as invoke } from 'node:child_process';
import { plan, prepare } from './plan.mjs';
import { progress } from './events.mjs';
import { embedded, compile } from '../../tools/inputs.mjs';
import { temporary as testOutput } from '../location.mjs';

const root = resolve(import.meta.dirname, '../..');
const completed = new Set();
const event = progress('proof', ['first.nim', 'second.nim'], completed);
assert.equal(event('ordinary output'), false);
assert.equal(event('FOO_NATIVE_CASE|another|first.nim|one'), false);
assert.equal(event('FOO_NATIVE_CASE|proof|first.nim|one'), true);
assert.equal(completed.size, 0, 'Case progress cannot count a module as completed');
for (const line of ['FOO_NATIVE_CASE|proof|first.nim|one', 'FOO_NATIVE_CASE|proof|missing.nim|two',
  'FOO_NATIVE_CASE|proof|first.nim|', 'FOO_NATIVE_CASE|proof|first.nim|two|extra'])
  assert.throws(() => event(line));
assert.equal(event('FOO_NATIVE_MODULE|proof|first.nim'), true);
assert.deepEqual([...completed], ['first.nim']);
assert.throws(() => event('FOO_NATIVE_MODULE|proof|first.nim'));
assert.throws(() => event('FOO_NATIVE_CASE|proof|first.nim|late'));
assert.equal(completed.size, 1, 'Incomplete group stays incomplete despite case progress');
const batched = plan(root);
const isolated = plan(root, { noBatching: true });
const modules = units => units.flatMap(unit => unit.modules).sort();
assert.deepEqual(modules(batched.units), modules(isolated.units), 'Grouping must preserve every active leaf exactly once');
assert.equal(new Set(modules(batched.units)).size, modules(batched.units).length);
assert(batched.units.length < isolated.units.length / 2);
const partial = plan(root, { ids: new Set(['types/borrow.nim', 'types/layout.nim']) });
assert.deepEqual(modules(partial.units), ['types/borrow.nim', 'types/layout.nim']);
assert.equal(partial.units.length, 1, 'Selected leaves in one suite should share a compile unit');
assert.equal(partial.units[0].fullSuite, false);
for (const module of ['types/layout.nim', 'backend/qbe/abi.nim', 'backend/qbe/driver.nim']) {
  const selected = plan(root, { filter: module });
  assert.deepEqual(modules(selected.units), [module], `Focused selection: ${module}`);
}
assert.equal(plan(root, { filter: 'does-not-exist' }).units.length, 0);
assert(modules(plan(root, { filter: 'backend/qbe/' }).units).every(module => module.startsWith('backend/qbe/')));
assert(embedded(root).includes(join(root, 'src/runtime/qbe.c')));
assert(embedded(root).includes(join(root, 'src/backend/qbe/wasm.nim')));

const temporary = testOutput();
try {
  const partialMain = read(prepare(partial.units[0], temporary), 'utf8');
  assert(!partialMain.includes('suites/syntax.nim'), 'Partial batches must not import unselected leaves');
  mkdir(join(temporary, 'test/.artifacts/ignored'), { recursive: true });
  mkdir(join(temporary, 'test/suites'), { recursive: true });
  write(join(temporary, 'test/.artifacts/ignored/generated.nim'), 'doAssert false');
  write(join(temporary, 'test/leaf.nim'), 'doAssert true');
  write(join(temporary, 'test/suites/unit.nim'), 'import ../leaf as leaf\n');
  assert.deepEqual(modules(plan(temporary).units), ['leaf.nim']);
  write(join(temporary, 'test/suites/duplicate.nim'), 'import ../leaf as leaf\n');
  assert.throws(() => plan(temporary), /duplicate/);

  // A compiler exit code alone cannot turn missing execution into coverage.
  const preload = join(temporary, 'compiler.cjs');
  for (const [name, body] of [['compile-failure', ''], ['missing-binary', 'process.exit(0)'],
    ['compiler-timeout', 'setInterval(() => {}, 1000)']]) {
    write(preload, `if (require('node:path').basename(process.argv[1] || '') === 'c') { ${body} }\n`);
    const output = join(temporary, name);
    const result = invoke(process.execPath, [join(root, 'test/native/run.mjs'), '--filter=types/layout.nim', `--output=${output}`],
      { env: { ...process.env, NIM_BIN: process.execPath, FOO_TEST_TIMEOUT: '1000',
        NODE_OPTIONS: '--require=' + JSON.stringify(preload.replaceAll('\\', '/')) }, encoding: 'utf8', windowsHide: true, timeout: 30000 });
    assert.notEqual(result.status, 0, name);
    const report = JSON.parse(read(join(output, 'summary.json')));
    assert.equal(report.complete, true);
    assert.equal(report.passed, false);
    assert.equal(report.executedSuites, 0, name);
    assert.equal(report.executedModules, 0, name);
  }

  if (process.argv.includes('--integration')) {
    const compiler = find();
    const file = join(temporary, 'main.nim');
    const binary = join(temporary, process.platform === 'win32' ? 'probe.exe' : 'probe');
    const cache = join(temporary, 'cache');
    write(file, 'import std/os\nconst payload = staticRead("input.txt")\ndoAssert payload == paramStr(1)\necho payload\n');
    for (const [payload, mm] of [['first', 'refc'], ['second', 'refc'], ['third', 'orc']]) {
      write(join(temporary, 'input.txt'), payload);
      const result = invoke(compiler, ['c', '-d:release', '--opt:size', `--mm:${mm}`, '--parallelBuild:2',
        ...(process.platform === 'win32' ? ['--cc:clang'] : []), `--nimcache:${cache}`, `-o:${binary}`, file],
      { encoding: 'utf8', windowsHide: true });
      assert.equal(result.status, 0, result.stdout + result.stderr);
      const run = invoke(binary, [payload], { encoding: 'utf8', windowsHide: true });
      assert.equal(run.status, 0, run.stdout + run.stderr);
      assert.equal(run.stdout.trim(), payload, 'Changed staticRead and memory-manager inputs must execute correctly without -f');
    }
    // Exercise the real runner with a progressing binary and final failures.
    write(file, `import std/os
import ${JSON.stringify(join(root, 'src/test/process').replaceAll('\\', '/'))}
let mode = getEnv("FOO_PROGRESS_TEST")
for index in 0 .. 3:
  sleep(400)
  if mode == "foreign":
    echo "FOO_NATIVE_CASE|another|types/layout.nim|", index
  else:
    mark("types/layout.nim", if mode == "duplicate": "same" else: $index)
  if mode == "stalled": sleep(5000)
if mode == "failure": quit(7)
`);
    const compiled = invoke(compiler, ['c', '-d:release', '--hints:off',
      ...(process.platform === 'win32' ? ['--cc:clang'] : []), `--nimcache:${cache}`, `-o:${binary}`, file],
    { encoding: 'utf8', windowsHide: true });
    assert.equal(compiled.status, 0, compiled.stdout + compiled.stderr);
    write(preload, `if (require('node:path').basename(process.argv[1] || '') === 'c') {
      require('node:fs').copyFileSync(${JSON.stringify(binary)}, process.argv.find(value => value.startsWith('--out:')).slice(6));
      process.exit(0);
    }\n`);
    for (const mode of ['success', 'failure', 'duplicate', 'foreign', 'stalled']) {
      const output = join(temporary, `progress-${mode}`);
      const result = invoke(process.execPath, [join(root, 'test/native/run.mjs'), '--filter=types/layout.nim', `--output=${output}`],
      { env: { ...process.env, NIM_BIN: process.execPath, FOO_TEST_TIMEOUT: '1000', FOO_PROGRESS_TEST: mode,
        NODE_OPTIONS: '--require=' + JSON.stringify(preload.replaceAll('\\', '/')) }, encoding: 'utf8', windowsHide: true, timeout: 30000 });
      const report = JSON.parse(read(join(output, 'summary.json')));
      assert.equal(result.status === 0, mode === 'success', result.stdout + result.stderr);
      assert.equal(report.passed, mode === 'success');
      if (mode === 'success') assert(report.results[0].runMs > 1000, 'Real case progress must extend the deadline');
      if (mode === 'foreign' || mode === 'stalled') assert.match(report.results[0].error, /Timed out/);
      if (mode === 'duplicate') assert.match(report.results[0].error, /duplicate case/);
      if (mode === 'failure') assert.equal(report.results[0].code, 7, 'Case progress cannot hide a failing final exit');
    }
    const suite = join(temporary, 'test/suites/unit.nim');
    write(suite, 'import ../leaf as leaf\nimport ../broken as broken\n');
    write(join(temporary, 'test/leaf.nim'), 'echo "leaf body ran"\n');
    const main = prepare({ file: suite, name: 'suites/unit.nim', modules: ['leaf.nim', 'broken.nim'] }, temporary);
    for (const failing of [true, false]) {
      write(join(temporary, 'test/broken.nim'), `doAssert ${failing ? 'false' : 'true'}\necho "second body ran"\n`);
      const compiled = invoke(compiler, ['c', '-d:release', '--mm:refc', '--parallelBuild:2',
        ...(process.platform === 'win32' ? ['--cc:clang'] : []), `--nimcache:${cache}`, `-o:${binary}`, main],
      { encoding: 'utf8', windowsHide: true });
      assert.equal(compiled.status, 0, compiled.stdout + compiled.stderr);
      const run = invoke(binary, [], { env: { ...process.env, FOOTESTID: 'wrapper-proof' }, encoding: 'utf8', windowsHide: true });
      assert.equal(run.status === 0, !failing, run.stdout + run.stderr);
      assert.equal((run.stdout.match(/leaf body ran/g) || []).length, 1, 'Original suite and wrappers must initialize each leaf only once');
      assert.equal((run.stdout.match(/FOO_NATIVE_MODULE\|wrapper-proof\|/g) || []).length, failing ? 1 : 2);
    }
    if (process.platform === 'win32') {
      const fixture = join(temporary, 'resources');
      mkdir(join(fixture, 'installers/windows'), { recursive: true });
      mkdir(join(fixture, 'installers/assets'), { recursive: true });
      copy(join(root, 'installers/assets/installer.ico'), join(fixture, 'installers/assets/installer.ico'));
      const rc = join(fixture, 'installers/windows/foo.rc');
      write(rc, '#define FOOICON 101\nFOOICON ICON "../assets/installer.ico"\n');
      const options = { root: fixture, cache: temporary };
      assert.equal(compile(options).hit, false);
      assert.equal(compile(options).hit, true);
      write(join(temporary, 'foo.res'), 'corrupt');
      assert.equal(compile(options).hit, false);
      write(rc, '#define FOOICON 102\nFOOICON ICON "../assets/installer.ico"\n');
      assert.equal(compile(options).hit, false);
      const icon = join(fixture, 'installers/assets/installer.ico');
      write(icon, Buffer.concat([read(icon), Buffer.from([0])]));
      assert.equal(compile(options).hit, false, 'Icon content changes must rebuild even if resource output stays equal');
      assert.equal(compile({ ...options, force: true }).hit, false);
    }
  }
  console.log(`Native suite coverage/filter/isolation gates passed: ${modules(batched.units).length} modules, ${batched.units.length} compile units.`);
} finally { remove(temporary, { recursive: true, force: true }); }
