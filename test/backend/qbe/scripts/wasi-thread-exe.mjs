import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Worker, isMainThread, parentPort, workerData } from 'node:worker_threads';

const binary = readFileSync(process.argv[2] || workerData?.binary);
const module = new WebAssembly.Module(binary);
const imports = WebAssembly.Module.imports(module);
assert(imports.some(item => item.module === 'env' && item.name === 'memory'));
assert(imports.some(item => item.module === 'wasi' && item.name === 'thread-spawn'));

if (!isMainThread) {
  const instance = new WebAssembly.Instance(module, {
    env: { memory: workerData.memory },
    wasi: { 'thread-spawn': () => -1 },
    wasi_snapshot_preview1: { proc_exit: () => {} },
  });
  instance.exports.wasi_thread_start(workerData.id, workerData.arg);
  parentPort.postMessage('done');
} else {
  const memory = new WebAssembly.Memory({ initial: 256, maximum: 1024,
    shared: true });
  const workers = [];
  let nextId = 1;
  let status = -1;
  const instance = new WebAssembly.Instance(module, {
    env: { memory },
    wasi: { 'thread-spawn': arg => {
      const id = nextId++;
      workers.push(new Worker(new URL(import.meta.url), {
        workerData: { binary: process.argv[2], memory, id, arg },
      }));
      return id;
    } },
    wasi_snapshot_preview1: { proc_exit: code => { status = code; } },
  });
  instance.exports._start();
  assert.equal(status, 0);
  assert.equal(workers.length, 4);
  await Promise.all(workers.map(worker => new Promise((resolve, reject) => {
    let completed = false;
    worker.once('message', message => {
      if (message !== 'done') reject(Error(`unexpected worker message: ${message}`));
      else completed = true;
    });
    worker.once('error', reject);
    worker.once('exit', code => {
      if (code !== 0 || !completed) reject(Error(`worker exit ${code}, completed=${completed}`));
      else resolve();
    });
  })));
  const address = instance.exports.thread_count.value;
  assert.equal(Atomics.load(new Int32Array(memory.buffer), address / 4), 4);
  console.log('standalone WASI threads executable: ok');
}
