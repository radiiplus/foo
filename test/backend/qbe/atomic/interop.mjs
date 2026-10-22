import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
const tcc = resolve(process.argv[2] || process.env.FOO_QBE_TCC ||
  (process.platform === 'win32' ? '.artifacts/qbe-win-package/bin/tcc.exe' :
    '/tmp/tratio-qbe-release/bin/tcc'));
const bin = dirname(tcc);
const linux = process.platform === 'linux';
const kit = resolve(bin, '../vendor/x64-musl');
const work = mkdtempSync(join(tmpdir(), 'qbe-atomic-interop-'));

function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, encoding: 'utf8',
    windowsHide: true });
  if (result.error || result.status !== 0)
    throw Error(`${command} ${args.join(' ')}: ${result.error?.message ||
      result.stdout + result.stderr}`);
  return result.stdout;
}

try {
  const object = join(work, linux ? 'foreign.o' : 'foreign.obj');
  const executable = join(work, linux ? 'atomic-interop' : 'atomic-interop.exe');
  const flags = linux ? ['-B', bin, '-I', join(kit, 'include')] : [];
  run(tcc, [...flags, '-std=c11', '-O0', '-c',
    'test/backend/qbe/atomic/foreign.c', '-o', object]);
  const inputs = linux ? ['-static', '-nostdlib', ...flags,
    join(kit, 'lib/crt1.o')] : [];
  inputs.push('src/runtime/qbe.c', 'test/backend/qbe/atomic/interop.c', object);
  if (linux) inputs.push(join(kit, 'lib/libc.a'), join(bin, 'libtcc1.a'));
  else inputs.push('tools/tcc/foo-winapi.def');
  run(tcc, [...inputs, '-o', executable]);
  const output = run(executable, []);
  if (output.trim() !== 'QBE foreign atomic interoperability: ok')
    throw Error(`Unexpected atomic probe output: ${output}`);
  console.log(output.trim());
} finally {
  rmSync(work, { recursive: true, force: true });
}
