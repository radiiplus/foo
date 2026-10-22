import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync,
  readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { detect as managedZig } from '../../toolchain.mjs';

if (process.platform !== 'linux' || process.arch !== 'x64')
  throw Error('The ARM64 assembler build requires a Linux x64 host');
const root = resolve(import.meta.dirname, '../../..');
const archive = resolve(process.argv[2] || join(root, '.artifacts/toolchain',
  'binutils-source_2.38-4ubuntu2.12_all.deb'));
const output = resolve(process.argv[3] || join(root, 'vendor/binutils/linux-arm64'));
const expected = '8893ca8f5b87a4e13012ec7a824fcc15ed974a183d6e69d2ce5456897258cddb';
if (!existsSync(archive))
  throw Error(`Download the pinned Ubuntu binutils-source 2.38-4ubuntu2.12 package first: ${archive}`);
if (createHash('sha256').update(readFileSync(archive)).digest('hex') !== expected)
  throw Error('Binutils source package SHA-256 mismatch');
const zig = managedZig();
if (!zig) throw Error('Building ARM64 assembler requires the managed Zig toolchain');
const work = mkdtempSync(join(tmpdir(), 'foo-arm64-as-'));
const unpacked = join(work, 'package');
const source = join(work, 'binutils-2.38');
const build = join(work, 'build');
mkdirSync(unpacked);
mkdirSync(build);

function run(command, args, cwd = work, env = process.env) {
  const result = spawnSync(command, args, { cwd, env, stdio: 'inherit' });
  if (result.error || result.status !== 0)
    throw Error(`${command} failed: ${result.error?.message || result.status}`);
}

run('dpkg-deb', ['-x', archive, unpacked]);
run('tar', ['-xf', join(unpacked, 'usr/src/binutils/binutils-2.38.tar.xz'),
  '-C', work]);
const env = { ...process.env,
  CC: `${zig.path} cc -target aarch64-linux-musl`,
  AR: `${zig.path} ar`, RANLIB: `${zig.path} ranlib`,
  CC_FOR_BUILD: 'gcc',
  CFLAGS: `-O2 -ffile-prefix-map=${work}=/usr/src/foo-binutils`,
  LDFLAGS: '-static -Wl,--build-id=none', SOURCE_DATE_EPOCH: '1764780000' };
run(join(source, 'configure'), [
  '--build=x86_64-linux-gnu', '--host=aarch64-linux-musl',
  '--target=aarch64-linux-musl', '--disable-nls', '--disable-werror',
  '--disable-gdb', '--disable-gprof', '--disable-gold', '--disable-ld',
  '--disable-binutils', '--disable-libctf', '--disable-shared',
  '--enable-static', '--without-zlib', '--without-zstd',
], build, env);
run('make', ['-s', '-j4', 'MAKEINFO=true', 'all-gas'], build, env);
const stripped = join(work, 'qbe-as-arm64');
run(process.env.FOO_ARM64_STRIP || 'llvm-strip', ['--strip-all', '-o', stripped,
  join(build, 'gas', 'as-new')]);
const binary = stripped;
const data = readFileSync(binary);
if (data.length < 20 || data.toString('ascii', 1, 4) !== 'ELF' ||
    data[4] !== 2 || data[5] !== 1 || data.readUInt16LE(18) !== 183)
  throw Error('Assembler build did not produce an ARM64 ELF executable');
mkdirSync(output, { recursive: true });
copyFileSync(binary, join(output, 'qbe-as-arm64'));
copyFileSync(join(unpacked, 'usr/share/doc/binutils-source/copyright'),
  join(output, 'COPYRIGHT'));
chmodSync(join(output, 'qbe-as-arm64'), 0o755);
console.log(`Built ARM64 assembler: ${join(output, 'qbe-as-arm64')}`);
