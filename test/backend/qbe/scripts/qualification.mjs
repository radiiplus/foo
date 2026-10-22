import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = resolve(import.meta.dirname, '../../../..');
const windows = process.platform === 'win32';
const distro = process.env.FOO_QBE_WSL_DISTRO || 'Ubuntu-22.04';

function guest(command, args, timeout = 30000) {
  const result = windows
    ? spawnSync('wsl.exe', ['-d', distro, '--exec', command, ...args],
        { encoding: 'utf8', timeout })
    : spawnSync(command, args, { encoding: 'utf8', timeout });
  assert.ok(!result.error, result.error?.message);
  return result;
}

function guestPath(path) {
  if (!windows) return path;
  const mapped = guest('wslpath', ['-a', path]);
  assert.equal(mapped.status, 0, mapped.stderr);
  return mapped.stdout.trim();
}

function artifact(folder, mode, name) {
  return resolve(root, '.artifacts', folder, mode, name);
}

function board(binary, target, expected, machine = '') {
  const image = guestPath(binary);
  const args = target === 'arm64'
    ? ['-M', machine || 'virt,gic-version=2', '-cpu', 'cortex-a53', '-nographic',
        '-device', `loader,file=${image},cpu-num=0`,
        '-serial', 'stdio', '-monitor', 'none']
    : ['-M', 'virt', '-nographic', '-bios', 'none',
        '-device', `loader,file=${image},cpu-num=0`,
        '-serial', 'stdio', '-monitor', 'none'];
  const run = guest('timeout', ['5s', `qemu-system-${target === 'arm64'
    ? 'aarch64' : 'riscv64'}`, ...args]);
  assert.equal(run.stdout, expected, `${binary}: ${run.stdout}\n${run.stderr}`);
}

const bootstrapSource = guestPath(resolve(root,
  'test/backend/qbe/fixtures/x64/irq/bootstrap.s'));
const bootstrapScript = guestPath(resolve(root,
  'test/backend/qbe/fixtures/x64/irq/bootstrap.ld'));
const bootstrapObject = guestPath(resolve(root,
  '.artifacts/qbe-x64-irqdelivery/bootstrap.o'));
const bootstrap = guestPath(resolve(root,
  '.artifacts/qbe-x64-irqdelivery/bootstrap.elf'));
assert.equal(guest('as', ['--32', '-o', bootstrapObject,
  bootstrapSource]).status, 0, 'x64 bootstrap assembly failed');
assert.equal(guest('ld', ['-m', 'elf_i386', '-T', bootstrapScript,
  '-o', bootstrap, bootstrapObject]).status, 0,
  'x64 bootstrap link failed');

for (const mode of ['dev', 'release']) {
  const x64 = artifact('qbe-x64-irqdelivery', mode,
    'qbe-x64-irq-delivery');
  assert.equal(readFileSync(x64).readBigUInt64LE(24), 0x100010n,
    'x64 bootstrap jump target changed');
  const x64Run = guest('timeout', ['5s', 'qemu-system-x86_64',
    '-M', 'pc', '-m', '128M', '-display', 'none', '-serial', 'none',
    '-monitor', 'none', '-device', 'isa-debugcon,iobase=0xe9,chardev=debug',
    '-chardev', 'stdio,id=debug', '-kernel', bootstrap,
    '-device', `loader,file=${guestPath(x64)}`]);
  assert.equal(x64Run.stdout, 'X', `${mode}: ${x64Run.stdout}\n${x64Run.stderr}`);

  board(artifact('qbe-arm64-irqdelivery', mode,
    'qbe-arm64-irq-delivery'), 'arm64', 'A');
  board(artifact('qbe-arm64-el2-delivery', mode,
    'qbe-arm64-el2-delivery'), 'arm64', '2',
    'virt,virtualization=on');
  board(artifact('qbe-arm64-el3-delivery', mode,
    'qbe-arm64-el3-delivery'), 'arm64', '3',
    'virt,secure=on,virtualization=on');
  board(artifact('qbe-irqdelivery', mode,
    'qbe-irq-delivery'), 'riscv64', 'IR');
  board(artifact('qbe-freestanding-integers',
    `arm64-freestanding-${mode}`, 'qbe-freestanding-integers'),
    'arm64', 'W');
  board(artifact('qbe-freestanding-integers',
    `riscv64-freestanding-${mode}`, 'qbe-freestanding-integers'),
    'riscv64', 'W');
  for (const target of ['x64', 'arm64', 'riscv64']) {
    const directory = `qbe-freestanding-memory/${target}-freestanding-${mode}`;
    const object = guestPath(artifact(directory, '', 'main.o'));
    const sections = guest('readelf', ['-SW', object]);
    assert.equal(sections.status, 0, sections.stderr);
    assert.match(sections.stdout,
      /\.percpu\s+PROGBITS[^\n]*\sWA\s+\d+\s+\d+\s+4096\s*$/m);
    const image = artifact(directory, '', 'qbe-freestanding-memory');
    const symbols = guest('readelf', ['-sW', guestPath(image)]);
    assert.equal(symbols.status, 0, symbols.stderr);
    const page = symbols.stdout.match(
      /^\s*\d+:\s+([0-9a-f]+)\s+.*storage\.cpu_page\s*$/m);
    assert.ok(page, `${image}: page symbol is missing`);
    assert.equal(BigInt(`0x${page[1]}`) % 4096n, 0n);
    if (target !== 'x64') board(image, target, 'W');
  }
  const x64Integer = guestPath(artifact('qbe-freestanding-integers',
    `x64-freestanding-${mode}`, 'qbe-freestanding-integers'));
  const x64Status = guest('sh', ['-c', `"${x64Integer}"; printf 'status:%s' "$?"`]);
  assert.equal(x64Status.stdout, 'status:42',
    `${mode}: ${x64Status.stdout}\n${x64Status.stderr}`);
  const x64Memory = guestPath(artifact('qbe-freestanding-memory',
    `x64-freestanding-${mode}`, 'qbe-freestanding-memory'));
  const memoryStatus = guest('sh', ['-c',
    `"${x64Memory}"; printf 'status:%s' "$?"`]);
  assert.equal(memoryStatus.stdout, 'status:42',
    `${mode}: ${memoryStatus.stdout}\n${memoryStatus.stderr}`);
  console.log(`${mode}: x64, ARM64 and RV64 interrupt/integer gates passed`);
}

const stressSource = guestPath(resolve(root,
  'test/backend/qbe/atomic/stress.c'));
const stressObject = guestPath(artifact('qbe-freestanding-memory',
  'x64-freestanding-release', 'main.o'));
const stressBinary = guestPath(artifact('qbe-freestanding-memory',
  'x64-freestanding-release', 'atomic-stress'));
const stressBuild = guest('gcc', ['-std=c11', '-O2', '-pthread',
  stressSource, stressObject, '-o', stressBinary]);
assert.equal(stressBuild.status, 0, stressBuild.stderr);
const stressRun = guest(stressBinary, []);
assert.equal(stressRun.status, 0, stressRun.stderr);
assert.equal(stressRun.stdout, 'atomic contention: ok\n');

await import('./uefi-boot.mjs');
