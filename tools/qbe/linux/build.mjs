import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, cpSync, mkdirSync, mkdtempSync,
  readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { detect as managedZig } from '../../toolchain.mjs';

if (process.platform !== 'linux' || process.arch !== 'x64')
  throw Error('The QBE Linux build requires a Linux x64 host');
const root = resolve(import.meta.dirname, '../../..');
const source = join(root, 'vendor/qbe');
const targetIndex = process.argv.indexOf('--target');
const target = targetIndex < 0 ? 'x64' : process.argv[targetIndex + 1];
if (!['x64', 'arm64'].includes(target))
  throw Error('--target must be x64 or arm64');
const outputIndex = process.argv.indexOf('--output');
const requested = outputIndex < 0 ? (process.argv[2]?.startsWith('--') ? '' : process.argv[2]) :
  process.argv[outputIndex + 1];
if (outputIndex >= 0 && (!requested || requested.startsWith('--')))
  throw Error('--output requires a path');
const output = resolve(requested || join(root, '.artifacts/toolchain/qbe',
  target === 'arm64' ? 'qbe-linux-arm64' : 'qbe-linux'));
mkdirSync(dirname(output), { recursive: true });
const work = mkdtempSync(join(dirname(output), 'linux-build-'));
cpSync(source, work, { recursive: true });
const cross = target === 'arm64';
const zig = cross ? managedZig() : undefined;
if (cross && !zig)
  throw Error('Cross-building QBE for ARM64 requires the managed Zig toolchain');
if (cross) writeFileSync(join(work, 'config.h'), '#define Deftgt T_arm64\n');
const built = spawnSync('make', ['-j2', 'qbe',
  ...(cross ? [`CC=${zig.path} cc -target aarch64-linux-musl -static`] : [])], {
  cwd: work, stdio: 'inherit', windowsHide: true,
});
if (built.error || built.status !== 0)
  throw Error(`QBE Linux build failed: ${built.error?.message || built.status}`);
const binary = readFileSync(join(work, 'qbe'));
const machine = cross ? 183 : 62;
if (binary.length < 20 || binary.toString('ascii', 1, 4) !== 'ELF' ||
    binary[4] !== 2 || binary[5] !== 1 || binary.readUInt16LE(18) !== machine)
  throw Error(`QBE Linux build produced the wrong ELF machine for ${target}`);
if (!cross || process.env.FOO_QBE_QEMU_AARCH64) {
  const runner = cross ? process.env.FOO_QBE_QEMU_AARCH64 : join(work, 'qbe');
  const args = cross ? [join(work, 'qbe'), '-t', '?'] : ['-t', '?'];
  const probe = spawnSync(runner, args, { encoding: 'utf8' });
  if (probe.error || probe.status !== 0 ||
      probe.stdout.trim() !== (cross ? 'arm64' : 'amd64_sysv'))
    throw Error(`QBE Linux target probe failed: ${probe.error?.message || probe.stderr || probe.stdout}`);
}
copyFileSync(join(work, 'qbe'), output);
chmodSync(output, 0o755);
console.log(`Built ${target} QBE: ${output}`);
