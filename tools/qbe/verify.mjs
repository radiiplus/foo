import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const packageIndex = process.argv.indexOf('--package');
const staged = packageIndex < 0 ? '' : resolve(process.argv[packageIndex + 1] || '');
if (packageIndex >= 0 && !process.argv[packageIndex + 1])
  throw Error('--package requires a staged release directory');
const qbe = staged ? join(staged, 'bin/qbe.exe') :
  resolve(process.argv[2] || join(root, '.artifacts/toolchain/qbe/qbe-win.exe'));
const tcc = staged ? join(staged, 'bin/tcc.exe') :
  resolve(process.argv[3] || join(root, '.artifacts/toolchain/tcc/vendor-build/source/win32/tcc.exe'));
const directory = mkdtempSync(join(tmpdir(), 'foo-qbe-bundle-'));

function run(executable, args) {
  const result = spawnSync(executable, args, { encoding: 'utf8', windowsHide: true });
  if (result.error || result.status !== 0)
    throw Error(`${executable} failed: ${result.error?.message || result.stderr || result.stdout}`);
  return result.stdout;
}

try {
  if (staged) {
    const receipt = JSON.parse(readFileSync(join(staged, 'toolchain/installed.json')));
    if (receipt.format !== 'foo.toolchain.installation' || receipt.target !== 'windows-x64')
      throw Error('Unexpected installed toolchain receipt');
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
  }
  if (!run(qbe, ['-t', '?']).includes('amd64_sysv'))
    throw Error('QBE native target probe failed');
  for (const [source, generated] of [
    ['provider/hosted.h', 'qbe-hashmap.h'],
    ['codec/json.h', 'qbe-json.h'],
    ['memory/storage.h', 'qbe-memory.h'],
    ['codec/qbe.h', 'qbe-codec.h'],
  ]) copyFileSync(join(root, 'src/runtime', source), join(directory, generated));
  for (const [name, source, marker] of [
    ['ownership', 'ownership.c', 'QBE ownership probe: ok'],
    ['runtime', 'tcc-runtime.c', 'QBE TinyCC runtime probe: ok'],
  ]) {
    const output = join(directory, `${name}.exe`);
    run(tcc, [`-I${directory}`, join(root, 'test/backend/qbe/c', source), join(root, 'src/runtime/qbe.c'),
      join(root, 'tools/tcc/foo-winapi.def'), '-o', output]);
    if (!run(output, []).includes(marker)) throw Error(`${name} result marker missing`);
  }
  const sse = join(directory, 'sse.exe');
  run(tcc, [join(root, 'test/backend/qbe/c/tcc-sse.c'),
    join(root, 'test/backend/qbe/c/tcc-sse.s'), '-o', sse]);
  if (!run(sse, []).includes('QBE TinyCC SSE probe: ok'))
    throw Error('TinyCC scalar SSE result marker missing');
  console.log('QBE Windows bundle verification: ok');
} finally {
  if (!resolve(directory).startsWith(resolve(tmpdir()) + sep))
    throw Error(`Refusing to remove unexpected test directory: ${directory}`);
  rmSync(directory, { recursive: true, force: true });
}
