import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { linux } from '../../../../tools/wsl.mjs';

const sdk = process.env.FOO_QBE_WASI_SDK;
const runner = process.env.FOO_QBE_WASI_THREADS_RUNNER;
assert.ok(sdk && runner, 'set FOO_QBE_WASI_SDK and FOO_QBE_WASI_THREADS_RUNNER');
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
const consumer = linux(join(root, 'test/backend/qbe/fixtures/threads.c'));

function run(command, args) {
  const result = spawnSync(process.platform === 'win32' ? 'wsl.exe' : command,
    process.platform === 'win32' ? ['-d', process.env.FOOWSL || 'Ubuntu-22.04',
      '--', command, ...args] : args,
    { encoding: 'utf8', windowsHide: true, timeout: 120000 });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${command}: ${result.stdout}${result.stderr}`);
}

for (const object of process.argv.slice(2)) {
  const output = join(dirname(object), 'consumer.wasm');
  run(`${sdk}/bin/wasm32-wasip1-threads-clang`, [
    `--sysroot=${sdk}/share/wasi-sysroot`, '-pthread',
    '-Wl,--initial-memory=16777216', '-Wl,--max-memory=67108864',
    '-Wl,--export-table', consumer, linux(object), '-o', linux(output)
  ]);
  run(runner, ['--max-threads=8', linux(output)]);
}
console.log('QBE WAT WASI threads C interop (dev/release): ok');
