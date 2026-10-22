import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const artifact = resolve(process.argv[2] || '');
assert.ok(process.argv[2], 'usage: node riscv/board.mjs <release ELF>');
const elf = readFileSync(artifact);
assert.equal(elf.subarray(0, 4).toString('hex'), '7f454c46');
assert.equal(elf[4], 2, 'expected ELF64');
assert.equal(elf.readUInt16LE(18), 243, 'expected RISC-V');

let kernel = artifact;
if (process.platform === 'win32') {
  const path = spawnSync('wsl.exe', ['--exec', 'wslpath', '-a', artifact],
    { encoding: 'utf8' });
  assert.equal(path.status, 0, path.stderr || path.error?.message);
  kernel = path.stdout.trim();
}

const qemu = process.platform === 'win32' ? 'wsl.exe' : 'timeout';
const args = [
  ...(process.platform === 'win32' ? ['--exec'] : []),
  'timeout', '8s', 'qemu-system-riscv64', '-M', 'virt', '-nographic',
  '-bios', 'none', '-kernel', kernel, '-serial', 'stdio', '-monitor', 'none',
];
if (process.platform !== 'win32') args.shift();
const run = spawnSync(qemu, args, { encoding: 'utf8', timeout: 15000 });
assert.equal(run.stdout, '*',
  `RISC-V board did not return 42 through the UART: ${run.stdout}\n${run.stderr}`);
assert.ok(run.status === 124 || run.status === 1,
  `unexpected QEMU status ${run.status}: ${run.stderr || run.error?.message}`);
console.log(`RISC-V release boot passed: ${artifact}`);
