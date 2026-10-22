#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { constants } from 'node:os';
import { Worker } from 'node:worker_threads';
import { WASI } from 'node:wasi';

const usage = 'usage: node tools/host/runner.mjs [--dir host::guest] program.wasm [arguments...]';
const args = process.argv.slice(2);
const preopens = {};
while (args[0] === '--dir') {
  args.shift();
  const pair = args.shift();
  const split = pair?.lastIndexOf('::') ?? -1;
  if (split < 1 || split === pair.length - 2) throw new Error(usage);
  preopens[pair.slice(split + 2)] = resolve(pair.slice(0, split));
}
if (!args.length) throw new Error(usage);
const wasm = resolve(args.shift());
const module = new WebAssembly.Module(readFileSync(wasm));
const allowed = new Set(['process_run', 'process_execute', 'process_id',
  'process_parent', 'process_spawn', 'process_write', 'process_seal',
  'process_read', 'process_identity', 'process_active', 'process_wait',
  'process_observe', 'process_signal', 'process_close', 'net_open',
  'net_accept', 'net_port', 'net_write', 'net_read', 'net_shutdown',
  'net_latency', 'net_probe', 'net_close']);
for (const item of WebAssembly.Module.imports(module)) {
  if (item.module === 'foo_host' && (item.kind !== 'function' || !allowed.has(item.name)))
    throw new Error(`Unsupported host import: ${item.module}.${item.name}`);
}
const wasi = new WASI({ version: 'preview1', args: [wasm, ...args],
  env: process.env, preopens, returnOnExit: true });
let memory;
let worker;
const decoder = new TextDecoder('utf-8', { fatal: true });
function view(pointer, length) {
  const bytes = new Uint8Array(memory.buffer);
  if (!Number.isInteger(pointer) || !Number.isInteger(length) ||
      pointer < 0 || length < 0 || pointer > bytes.length ||
      length > bytes.length - pointer)
    throw new RangeError('Host process argument exceeds WASI memory');
  return bytes.subarray(pointer, pointer + length);
}
function string(pointer, length) {
  const bytes = view(pointer, length);
  if (bytes.includes(0)) throw new TypeError('NUL in host process argument');
  return decoder.decode(bytes);
}
function status(command, argv, shell) {
  const child = spawnSync(command, argv, { shell, stdio: 'inherit', cwd: process.cwd() });
  if (child.error) return child.error.code === 'ENOENT' ? -5 : -3;
  if (child.status !== null) return child.status;
  const signal = constants.signals[child.signal];
  return signal ? 128 + signal : -3;
}
function request(op, payload = {}, capacity = 0) {
  worker ??= new Worker(new URL('./worker.mjs', import.meta.url));
  const shared = new SharedArrayBuffer(16 + capacity);
  const control = new Int32Array(shared, 0, 4);
  worker.postMessage({ op, payload, shared });
  if (Atomics.wait(control, 0, 0, 300000) === 'timed-out') return { value: -3 };
  return { value: Atomics.load(control, 1),
    bytes: new Uint8Array(shared, 16, Atomics.load(control, 2)) };
}
function collect(items, count) {
  if (count > 65536) throw new RangeError('Too many process arguments');
  const layout = new DataView(memory.buffer);
  view(items, count * 16);
  const argv = [];
  for (let index = 0; index < count; index++) {
    const at = items + index * 16;
    const size = layout.getBigUint64(at + 8, true);
    if (size > 0xffffffffn) throw new RangeError('Process argument is too long');
    argv.push(string(layout.getUint32(at, true), Number(size)));
  }
  return argv;
}
const host = {
  process_run(pointer, length) {
    try { return status(string(pointer, length), [], true); }
    catch { return -1; }
  },
  process_execute(pointer, length, items, count) {
    try {
      const program = string(pointer, length);
      return status(program, collect(items, count), false);
    } catch { return -1; }
  },
  process_id() { return process.pid; },
  process_parent() { return process.ppid; },
  process_spawn(pointer, length, items, count, piped) {
    try {
      return request('spawn', { program: string(pointer, length),
        argv: collect(items, count), piped: !!piped }).value;
    } catch { return -1; }
  },
  process_write(id, pointer, length) {
    try { return request('write', { id, bytes: Uint8Array.from(view(pointer, length)) }).value; }
    catch { return -1; }
  },
  process_seal(id) { return request('seal', { id }).value; },
  process_read(id, stream, pointer, length) {
    try {
      view(pointer, length);
      const result = request('read', { id, stream, length }, length);
      if (result.value > 0) view(pointer, result.value).set(result.bytes);
      return result.value;
    } catch { return -1; }
  },
  process_identity(id) { return request('identity', { id }).value; },
  process_active(id) { return request('active', { id }).value; },
  process_wait(id) { return request('wait', { id }).value; },
  process_observe(id, milliseconds) {
    return request('observe', { id, milliseconds }).value;
  },
  process_signal(id, signal) { return request('signal', { id, signal }).value; },
  process_close(id) { return request('close', { id }).value; },
  net_open(pointer, length, port, listener) {
    try { return request('net_open', { host: string(pointer, length),
      port, listener: !!listener }).value; }
    catch { return -2; }
  },
  net_accept(id) { return request('net_accept', { id }).value; },
  net_port(id) { return request('net_port', { id }).value; },
  net_write(id, pointer, length) {
    try { return request('net_write', { id,
      bytes: Uint8Array.from(view(pointer, length)) }).value; }
    catch { return -2; }
  },
  net_read(id, pointer, length) {
    try {
      view(pointer, length);
      const result = request('net_read', { id, length }, length);
      if (result.value > 0) view(pointer, result.value).set(result.bytes);
      return result.value;
    } catch { return -2; }
  },
  net_shutdown(id, direction) {
    return request('net_shutdown', { id, direction }).value;
  },
  net_latency(id, enabled) {
    return request('net_latency', { id, enabled: !!enabled }).value;
  },
  net_probe(id, enabled) {
    return request('net_probe', { id, enabled: !!enabled }).value;
  },
  net_close(id) { return request('net_close', { id }).value; },
};
const imports = { ...wasi.getImportObject(), foo_host: host };
const instance = new WebAssembly.Instance(module, imports);
memory = instance.exports.memory;
if (!(memory instanceof WebAssembly.Memory)) throw new Error('WASI memory export is missing');
try {
  const code = wasi.start(instance);
  process.exitCode = code;
  if (code) console.error(`WASI guest exited with status ${code}`);
}
finally { if (worker) await worker.terminate(); }
