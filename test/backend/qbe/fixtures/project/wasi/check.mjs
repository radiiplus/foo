import { readFileSync } from 'node:fs';

const binary = readFileSync(process.argv[2]);
let status = -1;
const module = await WebAssembly.instantiate(binary, {
  wasi_snapshot_preview1: { proc_exit: (code) => { status = code; } },
});
if (module.instance.exports.answer() !== 42)
  throw new Error('WASI scalar result changed');
let overflowed = false;
try {
  module.instance.exports.checked(2147483647);
} catch (error) {
  overflowed = error instanceof WebAssembly.RuntimeError;
}
if (!overflowed) throw new Error('checked overflow did not trap');
module.instance.exports._start();
if (status !== 0) throw new Error(`WASI exit status changed: ${status}`);
