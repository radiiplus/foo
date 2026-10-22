import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../../../..');
const version = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).version;
const packageRoot = resolve(process.argv[2] ||
  join(root, `release/foo-v${version}/foo-v${version}-linux-arm64`));
const qemu = process.env.FOO_QBE_QEMU_AARCH64 || 'qemu-aarch64-static';
const bin = join(packageRoot, 'bin');
const sysroot = join(packageRoot, 'vendor/arm64-musl');
const work = mkdtempSync(join(tmpdir(), 'foo-arm64-toolchain-'));

function run(program, args) {
  const result = spawnSync(program, args, { encoding: 'utf8' });
  if (result.error || result.status !== 0)
    throw Error(`${program} failed: ${result.error?.message || result.stderr ||
      result.stdout || result.status}`);
  return result.stdout;
}
function native(name, ...args) {
  const binary = join(bin, name);
  if (!existsSync(binary)) throw Error(`Missing ARM64 tool: ${binary}`);
  return run(qemu, [binary, ...args]);
}

const assembly = join(work, 'probe.s');
const object = join(work, 'probe.o');
const consumer = join(work, 'consumer.o');
const archive = join(work, 'probe.a');
const executable = join(work, 'probe');
writeFileSync(assembly, native('qbe', '-t', 'arm64',
  join(root, 'test/backend/qbe/fixtures/arm64-toolchain.ssa')));
if (!readFileSync(assembly, 'utf8').includes('foo_qbe_assembler_probe'))
  throw Error('QBE did not emit the probe function');
native('qbe-as-arm64', assembly, '-o', object);
native('arm64-tcc', '-B', bin, '-I', join(sysroot, 'include'), '-std=c11',
  '-c', join(root, 'test/backend/qbe/fixtures/arm64-toolchain.c'), '-o', consumer);
native('arm64-tcc', '-ar', 'rcs', archive, object);
native('arm64-tcc', '-static', '-nostdlib', '-B', bin,
  join(sysroot, 'lib/crt1.o'), consumer, archive, join(sysroot, 'lib/libc.a'),
  join(bin, 'arm64-libtcc1.a'), '-o', executable);
run(qemu, [executable]);
console.log('ARM64 QBE, assembler, TinyCC, archive and static execution: ok');
