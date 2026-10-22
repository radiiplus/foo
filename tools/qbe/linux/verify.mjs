import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const index = process.argv.indexOf('--package');
const staged = resolve(index < 0 ? join(root, '.artifacts/release-qbe-linux-probe') :
  process.argv[index + 1] || '');
if (index >= 0 && !process.argv[index + 1]) throw Error('--package requires a directory');
if (process.platform !== 'linux' || process.arch !== 'x64')
  throw Error('Run this verifier on Linux x64 (WSL is supported)');
const directory = mkdtempSync(join(tmpdir(), 'foo-qbe-linux-'));
const bin = join(staged, 'bin');
const qemu = process.env.FOO_QBE_QEMU_AARCH64 || 'qemu-aarch64-static';
const env = { ...process.env };
for (const name of ['FOO_QBE', 'FOO_QBE_CC', 'FOO_QBE_LINKER',
  'FOO_QBE_ARM64_SYSROOT', 'FOO_QBE_ARM64_LIBTCC',
  'FOO_QBE_X64_SYSROOT', 'FOO_QBE_X64_LIBTCC']) delete env[name];

function run(binary, args, cwd = directory) {
  const result = spawnSync(binary, args, { cwd, env, encoding: 'utf8' });
  if (result.error || result.status !== 0)
    throw Error(`${binary} failed (${result.status}): ${result.error?.message || result.stderr || result.stdout}`);
  return result.stdout;
}

try {
  const receipt = JSON.parse(readFileSync(join(staged, 'toolchain/installed.json')));
  if (receipt.format !== 'foo.toolchain.installation' || receipt.target !== 'linux-x64')
    throw Error('Unexpected Linux toolchain receipt');
  let total = 0;
  for (const asset of receipt.assets) {
    const path = resolve(staged, asset.path);
    if (!path.startsWith(staged + sep)) throw Error(`Unsafe asset path: ${asset.path}`);
    if (statSync(path).size !== asset.bytes ||
        createHash('sha256').update(readFileSync(path)).digest('hex') !== asset.sha256)
      throw Error(`Bundled asset differs from receipt: ${asset.path}`);
    total += asset.bytes;
  }
  if (total !== receipt.uncompressedBytes || total >= receipt.maximumUncompressedBytes)
    throw Error('Installed toolchain exceeds its recorded size limit');
  const assemblerFixture = join(root, 'test/backend/qbe/fixtures/assembler.ssa');
  for (const [qbeTarget, executable, machine] of [
    ['amd64_sysv', 'qbe-as', 'Advanced Micro Devices X86-64'],
    ['arm64', 'qbe-as-arm64', 'AArch64'],
    ['rv64', 'qbe-as-riscv64', 'RISC-V'],
  ]) {
    const assembly = join(directory, `${qbeTarget}.s`);
    const object = join(directory, `${qbeTarget}.o`);
    run(join(bin, 'qbe'), ['-t', qbeTarget, assemblerFixture, '-o', assembly]);
    run('env', [`LD_LIBRARY_PATH=${bin}`, join(bin, executable),
      assembly, '-o', object]);
    if (!run('readelf', ['-h', object]).includes(machine))
      throw Error(`${qbeTarget} assembler produced the wrong ELF machine`);
  }
  copyFileSync(join(root, 'test/backend/qbe/fixtures/entry.iv'), join(directory, 'entry.iv'));
  copyFileSync(join(root, 'benchmark/features/text.iv'), join(directory, 'text.iv'));
  for (const [target, cc, libtcc, musl, runner] of [
    ['linux-x64', 'tcc', 'libtcc1.a', 'x64-musl', null],
    ['linux-arm64', 'arm64-tcc', 'arm64-libtcc1.a', 'arm64-musl', qemu],
  ]) {
    run(join(bin, 'foo'), ['build', 'entry.iv', '--backend', 'qbe',
      '--mode', 'dev', '--target', target, '--compact']);
    const artifact = join(directory, '.artifacts/build/app');
    const metadata = JSON.parse(readFileSync(`${artifact}.qbe.json`));
    if (metadata.target !== target || metadata.cc.path !== join(bin, cc) ||
        metadata.compilerSupportSha256?.length !== 64)
      throw Error(`${target} compiler metadata is incomplete`);
    const segments = run('readelf', ['-l', artifact]);
    if (segments.includes('INTERP')) throw Error(`${target} executable is not static`);
    run(runner || artifact, runner ? [artifact] : []);

    const sysroot = join(staged, 'vendor', musl);
    const support = join(bin, libtcc);
    const runtime = join(directory, `${target}-runtime.o`);
    run(join(bin, cc), ['-B', bin, '-I', join(sysroot, 'include'), '-std=c11',
      '-c', join(root, 'src/runtime/qbe.c'), '-o', runtime]);
    const syscall = join(directory, `${target}-syscall.o`);
    const assembler = join(bin, target === 'linux-x64' ? 'qbe-as' : 'qbe-as-arm64');
    run('env', [`LD_LIBRARY_PATH=${bin}`, assembler,
      join(root, 'src/runtime/syscall', target === 'linux-x64' ?
        'x64.s' : 'arm64.s'), '-o', syscall]);
    for (const [probe, marker] of [
      ['ownership', 'QBE ownership probe: ok'],
      ['tcc-runtime', 'QBE TinyCC runtime probe: ok'],
      ['tcc-linux-runtime', 'QBE Linux syscall probe: ok'],
    ]) {
      const object = join(directory, `${target}-${probe}.o`);
      const executable = join(directory, `${target}-${probe}`);
      run(join(bin, cc), ['-B', bin, '-I', join(sysroot, 'include'), '-c',
        join(root, 'test/backend/qbe/c', `${probe}.c`), '-o', object]);
      run(join(bin, cc), ['-static', '-nostdlib', '-B', bin,
        join(sysroot, 'lib/crt1.o'), object, runtime, syscall,
        join(sysroot, 'lib/libc.a'), support, '-o', executable]);
      const output = run(runner || executable, runner ? [executable] : []);
      if (!output.includes(marker)) throw Error(`${target} ${probe} marker missing`);
    }
    run(join(bin, 'foo'), ['build', 'text.iv', '--backend', 'qbe',
      '--mode', 'dev', '--target', target, '--compact']);
    run(runner || artifact, runner ? [artifact] : []);
  }
  console.log(`QBE Linux package verification: ok (${total} toolchain bytes)`);
} finally {
  if (!directory.startsWith(resolve(tmpdir()) + sep))
    throw Error(`Refusing to remove unexpected test directory: ${directory}`);
  rmSync(directory, { recursive: true, force: true });
}
