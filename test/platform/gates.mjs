import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { release } from 'node:os';

if (process.platform !== 'linux') throw Error('Run this validation inside Linux/WSL after npm run build.');
const require = createRequire(import.meta.url);
const { Compiler } = require('../../.artifacts/compiler/src/build/compiler.js');
const { build: zig } = require('../../.artifacts/compiler/src/backend/zig/driver.js');
const { build: c } = require('../../.artifacts/compiler/src/backend/c/driver.js');
const { provision, capability, detect, version } = require('../../.artifacts/compiler/src/toolchain/manager.js');
const { encode } = require('../../.artifacts/compiler/src/ir/print.js');
const { decode } = require('../../.artifacts/compiler/src/ir/parse.js');
const { validate } = require('../../.artifacts/compiler/src/ir/valid.js');
const root = resolve('.artifacts/test');
const selected = process.argv.slice(2);
const names = ['existing', 'evaluation', 'aggregate', 'allocator', 'hardware', 'arm', 'riscv'];
if (selected.some(name => !names.includes(name))) throw Error('Choose checks from: ' + names.join(', '));
mkdirSync(root, { recursive: true });
const output = mkdtempSync(join(root, 'gates-'));
const results = [];
const backend = detect(version);
assert(backend, 'Install the pinned Linux toolchain before running validation.');
async function check(name, action) {
  if (selected.length && !selected.includes(name)) return;
  console.log('Checking ' + name);
  const start = performance.now();
  try {
    const detail = await action();
    results.push({ name, passed: true, detail, ms: performance.now() - start });
    console.log('PASS ' + name);
  } catch (error) {
    const detail = error.diagnostics?.messages.map(message => message.text).join('\n') || error.message;
    results.push({ name, passed: false, detail, ms: performance.now() - start });
    console.log('FAIL ' + name + ': ' + detail);
  }
}
function source(name, content) {
  const directory = join(output, name); mkdirSync(directory);
  const file = join(directory, 'main.iv');
  writeFileSync(file, '-- Exercises compiler and target execution contracts.\n' + content);
  return { directory, file };
}
function compile(file, directory) {
  const mod = new Compiler(directory).ir(file);
  assert.deepEqual(validate(mod), []);
  assert.equal(encode(decode(encode(mod))), encode(mod));
  writeFileSync(join(directory, 'module.json'), encode(mod));
  return mod;
}
function execute(name, content) {
  const { directory, file } = source(name, content);
  const mod = compile(file, directory);
  for (const [name, build] of [['zig', zig], ['c', c]]) {
    const result = build(mod, 'dev', join(directory, name), backend.path, file, { run: true });
    assert(result.success, result.error);
  }
  return 'IR validated and round-tripped; both native backends executed successfully on Linux x64.';
}

await check('existing', () => execute('existing', `
use memory.
use testing as check.
eval { constant answer is 40 plus 4. }
mutable total of type integer is 43.
start() {
  set total to total plus 1.
  check.expect(total is answer).
  constant owner is try memory.arena().
  after { memory.close(owner) catch nothing. }
  constant data is try allocate 8 using owner.
  mutable count is 0.
  for each item in data { check.expect(item is 0). set count to count plus 1. }
  check.expect(count is 8).
  give.
}`));
await check('evaluation', () => execute('evaluation', `
use testing as check.
function sum(value of type integer) of type integer {
  when value is 0 { give 0. }
  give value plus sum(value minus 1).
}
eval { constant answer is sum(8). }
start() { check.expect(answer is 36). give. }
`));
await check('aggregate', () => execute('aggregate', `
use testing as check.
type Pair is record { left of type integer. right of type integer. }.
mutable pair of type Pair is Pair(20, 24).
start() { check.expect(pair.left plus pair.right is 44). give. }
`));
await check('allocator', () => execute('allocator', `
function reserve(owner of type Allocator) of type fallible sequence of byte {
  give try allocate 8 using owner.
}
start() { give. }
`));
await check('hardware', async () => {
  const manifest = await provision('hardware');
  assert.equal(capability(), 'hardware');
  assert.equal(manifest.host, 'linux-' + process.arch);
  return manifest;
});

async function simulate(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', error;
    const timer = setTimeout(() => { error = new Error('Timed out waiting for the serial marker'); child.kill('SIGKILL'); }, 15000);
    child.on('error', cause => { error = cause; });
    child.stdout.on('data', chunk => {
      stdout += chunk.toString();
      if (stdout.includes('A')) child.kill('SIGTERM');
    });
    child.stderr.on('data', chunk => { stderr += chunk.toString(); });
    child.on('close', () => {
      clearTimeout(timer);
      if (error || !stdout.includes('A')) reject(new Error((error?.message || 'Serial marker missing') + '\n' + stderr));
      else resolve({ stdout, stderr, command, args });
    });
  });
}
for (const [name, target, emulator, address, options] of [
  ['arm', 'aarch64-freestanding-none', 'qemu-system-aarch64', 0x40000000, ['-cpu', 'cortex-a53']],
  ['riscv', 'riscv64-freestanding-none', 'qemu-system-riscv64', 0x80000000, ['-bios', 'none']],
]) await check(name, async () => {
  const fixtures = resolve('test/platform/fixtures');
  const { directory, file } = source(name, readFileSync(join(fixtures, name + '.iv'), 'utf8'));
  const mod = compile(file, directory);
  const result = zig(mod, 'release', join(directory, 'native'), backend.path, file, { target, runtime: 'none', run: false, debug: true, script: join(fixtures, name + '.ld') });
  assert(result.success, result.error);
  const bytes = readFileSync(result.artifact);
  assert.equal(bytes.subarray(0, 4).toString('hex'), '7f454c46');
  assert.equal(bytes[4], 2, 'Expected ELF64');
  assert.equal(bytes[5], 1, 'Expected little-endian ELF');
  assert.equal(bytes.readUInt16LE(18), name === 'arm' ? 183 : 243);
  const entry = Number(bytes.readBigUInt64LE(24));
  const sections = Number(bytes.readBigUInt64LE(40)), stride = bytes.readUInt16LE(58);
  let start;
  for (let index = 0; index < bytes.readUInt16LE(60); index++) {
    const section = sections + index * stride;
    if (bytes.readUInt32LE(section + 4) !== 2) continue;
    const strings = sections + bytes.readUInt32LE(section + 40) * stride;
    const names = Number(bytes.readBigUInt64LE(strings + 24));
    const offset = Number(bytes.readBigUInt64LE(section + 24));
    const size = Number(bytes.readBigUInt64LE(section + 32));
    const step = Number(bytes.readBigUInt64LE(section + 56));
    assert(step >= 24);
    for (let symbol = offset; symbol < offset + size; symbol += step) {
      const name = names + bytes.readUInt32LE(symbol);
      if (bytes.toString('utf8', name, bytes.indexOf(0, name)) === '_start') start = Number(bytes.readBigUInt64LE(symbol + 8));
    }
  }
  assert.equal(entry, start, 'The ELF entry must name the exported _start function');
  assert(entry >= address && entry < address + 128 * 1024 * 1024, 'Entry must be inside board RAM');
  const headers = Number(bytes.readBigUInt64LE(32));
  let executable = false;
  for (let index = 0; index < bytes.readUInt16LE(56); index++) {
    const segment = headers + index * bytes.readUInt16LE(54);
    const base = Number(bytes.readBigUInt64LE(segment + 16)), size = Number(bytes.readBigUInt64LE(segment + 40));
    if (bytes.readUInt32LE(segment) === 1 && (bytes.readUInt32LE(segment + 4) & 1) && entry >= base && entry < base + size) executable = true;
  }
  assert(executable, 'Entry must be in an executable load segment');
  // The generic loader sets the CPU's PC from the ELF entry. A Linux kernel
  // loader can instead enter a firmware reset vector at a fixed RAM address.
  return simulate(emulator, ['-machine', 'virt', '-m', '128M', ...options, '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-nic', 'none', '-device', `loader,file=${result.artifact},cpu-num=0`]);
});
const report = { format: 'foo.gates', version: 1, host: process.platform + '-' + process.arch, kernel: release(), backend: version, output, results };
writeFileSync(join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log('Report: ' + join(output, 'report.json'));
if (results.some(result => !result.passed)) process.exitCode = 1;
