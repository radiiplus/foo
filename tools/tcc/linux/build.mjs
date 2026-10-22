import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, cpSync, mkdirSync, mkdtempSync,
  readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { detect as managedZig } from '../../toolchain.mjs';

if (process.platform !== 'linux' || process.arch !== 'x64')
  throw Error('The ARM64 TinyCC build requires a Linux x64 host');
const root = resolve(import.meta.dirname, '../../..');
const source = join(root, 'vendor/tcc');
const output = resolve(process.argv[2] || join(root, '.artifacts/toolchain/tcc/linux-arm64'));
const zig = managedZig();
if (!zig) throw Error('Building ARM64 TinyCC requires the managed Zig toolchain');
mkdirSync(output, { recursive: true });
const work = mkdtempSync(join(output, 'build-'));
cpSync(source, work, { recursive: true });
const configure = join(work, 'configure');
writeFileSync(configure, readFileSync(configure, 'utf8').replaceAll('\r\n', '\n'));

function run(command, args) {
  const result = spawnSync(command, args, { cwd: work, stdio: 'inherit' });
  if (result.error || result.status !== 0)
    throw Error(`${command} failed: ${result.error?.message || result.status}`);
}

run('sh', ['./configure', '--cpu=arm64', '--cc=gcc', '--config-static']);
run('make', ['tccdefs_.h']);
run('make', ['-j2', 'tcc', `CC=${zig.path} cc -target aarch64-linux-musl`,
  `AR=${zig.path} ar`,
  `CFLAGS=-O2 -ffile-prefix-map=${work}=/usr/src/foo-tcc`,
  'LDFLAGS=-static -Wl,--build-id=none', 'GITHASH=no']);
run(process.env.FOO_ARM64_STRIP || 'llvm-strip', ['--strip-all', '-o',
  join(work, 'arm64-tcc'), join(work, 'tcc')]);
const binary = readFileSync(join(work, 'arm64-tcc'));
if (binary.length < 20 || binary.toString('ascii', 1, 4) !== 'ELF' ||
    binary[4] !== 2 || binary[5] !== 1 || binary.readUInt16LE(18) !== 183)
  throw Error('TinyCC build did not produce an ARM64 ELF executable');
copyFileSync(join(work, 'arm64-tcc'), join(output, 'arm64-tcc'));
copyFileSync(join(source, 'COPYING'), join(output, 'COPYING'));
chmodSync(join(output, 'arm64-tcc'), 0o755);
console.log(`Built ARM64 TinyCC: ${join(output, 'arm64-tcc')}`);
