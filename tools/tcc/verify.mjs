import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'win32' || process.arch !== 'x64')
  throw Error('The TinyCC vectorcall probe requires Windows x64');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const tcc = resolve(process.argv[2] || join(root,
  '.artifacts/toolchain/tcc/vendor-build/source/win32/tcc.exe'));
const directory = mkdtempSync(join(tmpdir(), 'foo-tcc-vectorcall-'));

function run(program, args) {
  const result = spawnSync(program, args, { encoding: 'utf8', windowsHide: true });
  if (result.error || result.status !== 0)
    throw Error(`${program} failed: ${result.error?.message || result.stderr || result.stdout}`);
}

try {
  const tccObject = join(directory, 'tcc.o');
  const peerObject = join(directory, 'peer.o');
  const executable = join(directory, 'vectorcall.exe');
  run(tcc, ['-c', join(root, 'test/backend/qbe/vectorcall/tcc.c'), '-o', tccObject]);
  run(tcc, ['-c', join(root, 'test/backend/qbe/vectorcall/self.c'), '-o', peerObject]);
  run(tcc, [tccObject, peerObject, '-o', executable]);
  run(executable, []);
  console.log('TinyCC Windows x64 vectorcall probe: ok');
} finally {
  if (!resolve(directory).startsWith(resolve(tmpdir()) + sep))
    throw Error(`Unsafe TinyCC probe directory: ${directory}`);
  rmSync(directory, { recursive: true, force: true });
}
