import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { execFileSync } from 'node:child_process';
const require = createRequire(import.meta.url);
const { Compiler } = require('../../.artifacts/compiler/src/build/compiler.js');
const { build: c } = require('../../.artifacts/compiler/src/backend/c/driver.js');
const { build: zig } = require('../../.artifacts/compiler/src/backend/zig/driver.js');
const { bind } = require('../../.artifacts/compiler/src/interop/bind.js');
const { detect } = require('../../.artifacts/compiler/src/toolchain/manager.js');
const { escape } = require('../../.artifacts/compiler/src/backend/native/escape.js');
const { emit } = require('../../.artifacts/compiler/src/backend/c/emitter.js');
assert.equal(process.platform, 'linux', 'Run this gate on Linux or inside WSL');
mkdirSync('.artifacts/test', { recursive: true });
const root = mkdtempSync(resolve('.artifacts/test/foo-language-linux-'));
writeFileSync(join(root, 'project.json'), JSON.stringify({ requires: 'machine' }));
const tool = detect('0.16.0'); assert(tool);
const results = [];
for (const name of ['escape', 'machine', 'system', 'library']) {
  const input = name === 'library' ? readFileSync('test/interop/library.iv', 'utf8') : name === 'system'
    ? '-- Checks a direct Linux system call.\nuse testing as check. start() { constant pid is call system call 39. check.expect(pid greater than 0). }\n'
    : readFileSync(`test/native/${name}.iv`, 'utf8');
  const source = join(root, name + '.iv'); writeFileSync(source, input);
  const module = new Compiler(root, "zig", [], "release").ir(source);
  for (const [backend, build] of [['c', c], ['zig', zig]]) {
    const output = join(root, name, backend);
    const built = build(module, 'release', output, tool.path, source, { level: 'machine', native: { substrate: 'c', clobbers: ['rax'] }, run: false, ...(backend === 'c' ? { compiler: 'gcc' } : {}), ...(name === 'library' ? { libs: ['sodium'] } : {}) });
    assert(built.success, built.error);
    execFileSync(built.artifact, [], { timeout: 60000 });
    results.push({ name, backend, executed: true }); console.log(`${name}/${backend} passed`);
  }
}
const imported = bind('/usr/include/sodium/crypto_verify_16.h', { cacheDir: join(root, 'bindings') });
assert(!imported.diagnostics.some(item => item.code === 'C_UNBINDABLE'));
assert.equal(bind('/usr/include/sodium/crypto_verify_16.h', { cacheDir: join(root, 'bindings') }).cached, true);
assert.match(imported.source, /crypto_verify_16_BYTES/);
const atomic = join(root, 'atomic.iv');
writeFileSync(atomic, '-- Checks cross-target atomic and bit lowering.\nmutable counter of type unsigned 64 is 0. function increment() { atomic add counter by 1. } start() { increment(). }\n');
const module = new Compiler(root).ir(atomic);
for (const target of ['x86_64-linux-gnu', 'aarch64-linux-gnu']) {
  const output = join(root, target); mkdirSync(output);
  const escaped = escape(module, { target, level: 'machine' });
  const generated = join(output, 'atomic.c'), assembly = join(output, 'atomic.s');
  writeFileSync(generated, emit(escaped.module, 'release', { target, level: 'machine' }).code);
  execFileSync(tool.path, ['cc', '-target', target, '-O2', '-S', generated, '-o', assembly]);
  const text = readFileSync(assembly, 'utf8');
  assert.match(text, target.startsWith('x86_64') ? /lock[\s\S]{0,40}(?:add|xadd|inc)/ : /ldadd|ldaxr|__aarch64_ldadd/);
  const built = zig(module, 'release', join(output, 'zig'), tool.path, atomic, { target: target.replace('gnu', 'musl'), level: 'machine', run: false });
  assert(built.success, built.error);
  const disassembly = execFileSync('llvm-objdump-14', ['-d', built.artifact], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  assert.match(disassembly, target.startsWith('aarch64') ? /ldadd|ldaxr|ldxr|__aarch64_ldadd/ : /lock|xadd/);
  results.push({ name: 'atomic', target, assembly, executed: false, inspected: true });
}
writeFileSync(join(root, 'results.json'), JSON.stringify({ version: 1, results, binding: imported.bindingPath }, null, 2));
console.log(`Linux native/FFI and atomic architecture evidence: ${root}`);
