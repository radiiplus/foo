import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = resolve(import.meta.dirname, '../../../..');
const distro = process.env.FOO_QBE_WSL_DISTRO || 'Ubuntu-22.04';
const windows = process.platform === 'win32';

function guest(command, args, timeout = 30000) {
  const result = spawnSync(windows ? 'wsl.exe' : command,
    windows ? ['-d', distro, '--exec', command, ...args] : args,
    { encoding: 'utf8', timeout });
  assert.ok(!result.error, result.error?.message);
  return result;
}

function guestPath(path) {
  if (!windows) return path;
  const converted = guest('wslpath', ['-a', path]);
  assert.equal(converted.status, 0, converted.stderr);
  return converted.stdout.trim();
}

for (const mode of ['dev', 'release']) {
  const image = resolve(root, '.artifacts/qbe-uefi', mode, 'BOOTX64.efi');
  const bytes = readFileSync(image);
  const pe = bytes.readUInt32LE(0x3c);
  assert.equal(bytes.toString('ascii', pe, pe + 4), 'PE\0\0');
  assert.equal(bytes.readUInt16LE(pe + 4), 0x8664);
  assert.equal(bytes.readUInt16LE(pe + 24), 0x20b);
  assert.equal(bytes.readUInt16LE(pe + 24 + 68), 10);
  assert.equal(bytes.readUInt32LE(pe + 24 + 112 + 1 * 8 + 4), 0,
    'UEFI image must not import hosted libraries');
  assert.equal(bytes.readUInt16LE(pe + 24 + 70) & 0x40, 0x40,
    'UEFI image must be relocatable');
  assert.notEqual(bytes.readUInt32LE(pe + 24 + 112 + 5 * 8 + 4), 0,
    'UEFI image needs base relocations');
  const boot = resolve(root, '.artifacts/qbe-uefi/ovmf', mode);
  const directory = resolve(boot, 'EFI/BOOT');
  mkdirSync(directory, { recursive: true });
  copyFileSync(image, resolve(directory, 'BOOTX64.EFI'));
  const run = guest('timeout', ['20s', 'qemu-system-x86_64',
    '-M', 'q35', '-m', '256M', '-display', 'none', '-serial', 'none',
    '-monitor', 'none', '-net', 'none', '-bios', '/usr/share/ovmf/OVMF.fd',
    '-drive', `file=fat:rw:${guestPath(boot)},format=raw,if=ide`,
    '-device', 'isa-debugcon,iobase=0xe9,chardev=debug',
    '-chardev', 'stdio,id=debug'], 25000);
  assert.match(run.stdout, /U/, `${mode}: ${run.stdout}\n${run.stderr}`);
  console.log(`${mode}: OVMF EFI entry executed`);
}
