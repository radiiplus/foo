import assert from 'node:assert/strict';
import {
  copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync,
} from 'node:fs';
import { resolve, join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { release } from 'node:os';

if (process.platform !== 'linux')
  throw Error('Run this validation inside Linux/WSL after building a Linux compiler.');
const compiler = process.env.FOO_BIN
  ? resolve(process.env.FOO_BIN)
  : resolve('.artifacts/compiler/bin/foo');
assert(existsSync(compiler), `Missing Linux FOO compiler: ${compiler}`);
const root = resolve('.artifacts/test');
const selected = process.argv.slice(2);
const names = ['existing', 'evaluation', 'aggregate', 'allocator', 'hardware', 'arm', 'riscv'];
if (selected.some(name => !names.includes(name)))
  throw Error('Choose checks from: ' + names.join(', '));
mkdirSync(root, { recursive: true });
const output = mkdtempSync(join(root, 'gates-'));
const results = [];

function invoke(directory, args) {
  const result = spawnSync(compiler, args, {
    cwd: directory,
    encoding: 'utf8',
    env: process.env,
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0)
    throw Error(`${args.join(' ')} failed\n${result.stdout}${result.stderr}`);
  return result;
}

async function check(name, action) {
  if (selected.length && !selected.includes(name)) return;
  console.log('Checking ' + name);
  const start = performance.now();
  try {
    const detail = await action();
    results.push({ name, passed: true, detail, ms: performance.now() - start });
    console.log('PASS ' + name);
  } catch (error) {
    results.push({ name, passed: false, detail: error.message, ms: performance.now() - start });
    console.log('FAIL ' + name + ': ' + error.message);
  }
}

function project(name, content, build = {}) {
  const directory = join(output, name);
  const source = join(directory, 'src');
  mkdirSync(source, { recursive: true });
  const file = join(source, 'main.iv');
  writeFileSync(file, '-- Exercises compiler and target execution contracts.\n' + content);
  writeFileSync(join(directory, 'project.json'), JSON.stringify({
    schema: 1,
    name,
    version: '0.1.0',
    language: '1',
    source: 'src',
    entry: 'src/main.iv',
    requires: 'hardware',
    dependencies: {},
    build,
  }, null, 2) + '\n');
  return { directory, file };
}

function execute(name, content) {
  const item = project(name, content);
  for (const backend of ['zig', 'c'])
    invoke(item.directory, ['run', '--backend', backend]);
  return 'Both native backends compiled and executed the checked program.';
}

await check('existing', () => execute('existing', `
use memory.
use testing as check.
eval { constant answer is 40 plus 4. }
dynamic total is 43.
start {
  set total to total plus 1.
  check.expect(total is answer).
  constant owner is memory.arena try.
  after { memory.close(owner) fallback nothing. }
  constant data is allocate 8 using owner try.
  dynamic count is 0.
  for each item in data { check.expect(item is 0). set count to count plus 1. }
  check.expect(count is 8).
}
`));
await check('evaluation', () => execute('evaluation', `
use testing as check.
eval { constant answer is 8 multiply 9. }
start { check.expect(answer is 72). }
`));
await check('aggregate', () => execute('aggregate', `
use testing as check.
define Pair as record { left of type integer. right of type integer. }.
start {
  constant pair is Pair(20, 24).
  check.expect(pair.left plus pair.right is 44).
}
`));
await check('allocator', () => execute('allocator', `
use memory.
use sequence as sequences.
use testing as check.
start {
  constant owner is memory.arena try.
  after { memory.close(owner) fallback nothing. }
  constant data is allocate 8 using owner try.
  check.expect(sequences.length[byte](data) is 8).
}
`));
await check('hardware', () => {
  invoke(resolve('.'), ['toolchain', 'install', 'hardware']);
  return 'The managed toolchain and hardware capability receipt are ready.';
});

async function simulate(command, args) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', error;
    const timer = setTimeout(() => {
      error = new Error('Timed out waiting for the serial marker');
      child.kill('SIGKILL');
    }, 15000);
    child.on('error', cause => { error = cause; });
    child.stdout.on('data', chunk => {
      stdout += chunk.toString();
      if (stdout.includes('A')) child.kill('SIGTERM');
    });
    child.stderr.on('data', chunk => { stderr += chunk.toString(); });
    child.on('close', () => {
      clearTimeout(timer);
      if (error || !stdout.includes('A'))
        reject(error || new Error('Serial marker missing\n' + stderr));
      else resolvePromise({ stdout, stderr, command, args });
    });
  });
}

function inspect(path, machine, address) {
  const bytes = readFileSync(path);
  assert.equal(bytes.subarray(0, 4).toString('hex'), '7f454c46');
  assert.equal(bytes[4], 2, 'Expected ELF64');
  assert.equal(bytes[5], 1, 'Expected little-endian ELF');
  assert.equal(bytes.readUInt16LE(18), machine);
  const entry = Number(bytes.readBigUInt64LE(24));
  const sections = Number(bytes.readBigUInt64LE(40));
  const stride = bytes.readUInt16LE(58);
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
      const symbolName = names + bytes.readUInt32LE(symbol);
      if (bytes.toString('utf8', symbolName, bytes.indexOf(0, symbolName)) === '_start')
        start = Number(bytes.readBigUInt64LE(symbol + 8));
    }
  }
  assert.equal(entry, start, 'The ELF entry must name the exported _start function');
  assert(entry >= address && entry < address + 128 * 1024 * 1024,
    'Entry must be inside board RAM');
  const headers = Number(bytes.readBigUInt64LE(32));
  let executable = false;
  for (let index = 0; index < bytes.readUInt16LE(56); index++) {
    const segment = headers + index * bytes.readUInt16LE(54);
    const base = Number(bytes.readBigUInt64LE(segment + 16));
    const size = Number(bytes.readBigUInt64LE(segment + 40));
    if (bytes.readUInt32LE(segment) === 1 && (bytes.readUInt32LE(segment + 4) & 1)
        && entry >= base && entry < base + size) executable = true;
  }
  assert(executable, 'Entry must be in an executable load segment');
}

for (const [name, target, machine, emulator, address, options] of [
  ['arm', 'arm64-freestanding', 183, 'qemu-system-aarch64', 0x40000000,
    ['-cpu', 'cortex-a53']],
  ['riscv', 'riscv64-freestanding', 243, 'qemu-system-riscv64', 0x80000000,
    ['-bios', 'none']],
]) await check(name, async () => {
  const fixtures = resolve('test/platform/fixtures');
  const item = project(name, readFileSync(join(fixtures, name + '.iv'), 'utf8'), {
    target: [target],
    optimize: 'release',
    runtime: 'none',
    link: { script: 'board.ld' },
  });
  copyFileSync(join(fixtures, name + '.ld'), join(item.directory, 'board.ld'));
  for (const backend of ['zig', 'c']) {
    invoke(item.directory, ['build', '--backend', backend, '--target', target]);
    const artifact = join(item.directory, 'target', 'app');
    inspect(artifact, machine, address);
    await simulate(emulator, ['-machine', 'virt', '-m', '128M', ...options,
      '-display', 'none', '-monitor', 'none', '-serial', 'stdio', '-nic', 'none',
      '-device', `loader,file=${artifact},cpu-num=0`]);
  }
  return { backends: 2, target };
});

const version = invoke(resolve('.'), ['version']).stdout.trim();
const report = {
  format: 'foo.gates', version: 1, compiler: version,
  host: process.platform + '-' + process.arch, kernel: release(), output, results,
};
writeFileSync(join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log('Report: ' + join(output, 'report.json'));
if (results.some(result => !result.passed)) process.exitCode = 1;
