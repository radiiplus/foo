import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

assert.equal(process.platform, 'linux', 'run this gate under Linux or WSL');
assert.equal(process.argv.length, 4,
  'usage: node riscv/tcc-board.mjs <QBE assembly> <startup assembly>');
const tcc = process.env.FOO_RISCV_TCC || 'riscv64-tcc';
const directory = mkdtempSync(join(tmpdir(), 'qbe-riscv-tcc-'));
const qbeAssembly = resolve(process.argv[2]);
const startupAssembly = resolve(process.argv[3]);
const translated = join(directory, 'main.s');
const mainObject = join(directory, 'main.o');
const startupObject = join(directory, 'startup.o');
const image = join(directory, 'app.bin');

const generated = readFileSync(qbeAssembly, 'utf8')
  .replace(/\bfp\b/g, 's0')
  .replace(/^(\s*)add(?=\s+\w+,\s*\w+,\s*-?\d+\s*$)/gm, '$1addi');
writeFileSync(translated, generated);

function run(command, args, timeout = 15000) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout });
  assert.equal(result.status, 0,
    `${command} failed: ${result.stderr || result.error?.message}`);
  return result;
}

run(tcc, ['-c', translated, '-o', mainObject]);
run(tcc, ['-c', startupAssembly, '-o', startupObject]);
run(tcc, ['-nostdlib', '-static', '-Wl,-Ttext=0x80000000',
  '-Wl,-e=_start', '-Wl,-oformat=binary', startupObject, mainObject,
  '-o', image]);

const qemu = spawnSync('timeout', ['8s', 'qemu-system-riscv64', '-M', 'virt',
  '-nographic', '-bios', image, '-serial', 'stdio', '-monitor', 'none'],
{ encoding: 'utf8', timeout: 15000 });
assert.equal(qemu.stdout, '*',
  `TinyCC RISC-V image did not return 42: ${qemu.stdout}\n${qemu.stderr}`);
assert.ok(qemu.status === 124 || qemu.status === 1,
  `unexpected QEMU status ${qemu.status}: ${qemu.stderr || qemu.error?.message}`);
const bytes = readFileSync(image);
console.log(`TinyCC RISC-V boot passed: ${bytes.length} bytes, SHA-256 ${
  createHash('sha256').update(bytes).digest('hex')}`);
