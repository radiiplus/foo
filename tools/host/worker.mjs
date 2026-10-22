import { spawn } from 'node:child_process';
import { constants } from 'node:os';
import { createConnection, createServer } from 'node:net';
import { parentPort } from 'node:worker_threads';

const children = new Map();
let identifier = 1;
const sockets = new Map();
let serial = 1;

function result(shared, value, bytes = Buffer.alloc(0)) {
  const control = new Int32Array(shared, 0, 4);
  if (bytes.length) new Uint8Array(shared, 16, bytes.length).set(bytes);
  Atomics.store(control, 1, value);
  Atomics.store(control, 2, bytes.length);
  Atomics.store(control, 0, 1);
  Atomics.notify(control, 0);
}
function code(child) {
  if (child.exitCode !== null) return child.exitCode;
  const signal = constants.signals[child.signalCode];
  return signal ? 128 + signal : 255;
}
function finished(child) {
  return child.exitCode !== null || child.signalCode !== null;
}
function exited(child) {
  if (finished(child)) return Promise.resolve();
  return new Promise(resolve => child.once('exit', resolve));
}
function channel(stream) {
  const queued = [];
  let size = 0;
  let ended = false;
  let wake;
  const notify = () => { if (wake) { const resolve = wake; wake = null; resolve(); } };
  stream.on('data', bytes => {
    queued.push(Buffer.from(bytes));
    size += bytes.length;
    if (size >= 1048576) stream.pause();
    notify();
  });
  for (const event of ['end', 'close', 'error'])
    stream.on(event, () => { ended = true; notify(); });
  return {
    async read(limit) {
      while (!queued.length && !ended)
        await new Promise(resolve => { wake = resolve; });
      if (!queued.length) return Buffer.alloc(0);
      const first = queued[0];
      const bytes = first.subarray(0, limit);
      if (bytes.length === first.length) queued.shift();
      else queued[0] = first.subarray(limit);
      size -= bytes.length;
      if (size < 524288) stream.resume();
      return bytes;
    },
  };
}
async function handle(op, data) {
  if (op === 'net_open') {
    if (data.listener) {
      const server = createServer({ allowHalfOpen: true });
      const error = await new Promise(resolve => {
        server.once('listening', () => resolve(null));
        server.once('error', resolve);
        server.listen(data.port, data.host || undefined);
      });
      if (error) return { value: -3 };
      const id = serial++;
      const item = { server, pending: [] };
      server.on('connection', socket => {
        socket.on('error', () => {});
        item.pending.push({ socket, stream: channel(socket) });
      });
      sockets.set(id, item);
      return { value: id };
    }
    const socket = createConnection({ host: data.host, port: data.port,
      allowHalfOpen: true });
    const stream = channel(socket);
    const error = await new Promise(resolve => {
      socket.once('connect', () => resolve(null));
      socket.once('error', resolve);
    });
    if (error) return { value: -3 };
    socket.on('error', () => {});
    const id = serial++;
    sockets.set(id, { socket, stream });
    return { value: id };
  }
  if (op.startsWith('net_')) {
    const item = sockets.get(data.id);
    if (!item) return { value: -4 };
    if (op === 'net_port') {
      const address = (item.server || item.socket).address();
      return { value: address?.port ?? -3 };
    }
    if (op === 'net_accept') {
      if (!item.server) return { value: -2 };
      if (!item.pending.length) await new Promise(resolve =>
        item.server.once('connection', resolve));
      const accepted = item.pending.shift();
      const id = serial++;
      sockets.set(id, accepted);
      return { value: id };
    }
    if (op === 'net_close') {
      if (item.server) {
        for (const pending of item.pending) pending.socket.destroy();
        item.server.close();
      }
      else item.socket.destroy();
      sockets.delete(data.id);
      return { value: 0 };
    }
    const socket = item.socket;
    if (!socket) return { value: -2 };
    if (op === 'net_write') {
      return new Promise(resolve => socket.write(data.bytes, error =>
        resolve({ value: error ? -3 : data.bytes.length })));
    }
    if (op === 'net_read') {
      const bytes = await item.stream.read(data.length);
      return { value: bytes.length, bytes };
    }
    if (op === 'net_shutdown') {
      if (data.direction === 1) socket.end();
      else if (data.direction === 2) socket.destroy();
      else return { value: -2 };
      return { value: 0 };
    }
    if (op === 'net_latency') {
      socket.setNoDelay(data.enabled);
      return { value: 0 };
    }
    if (op === 'net_probe') {
      socket.setKeepAlive(data.enabled);
      return { value: 0 };
    }
    return { value: -2 };
  }
  if (op === 'spawn') {
    const child = spawn(data.program, data.argv,
      { stdio: data.piped ? ['pipe', 'pipe', 'pipe'] : 'inherit' });
    const output = data.piped ? channel(child.stdout) : null;
    const report = data.piped ? channel(child.stderr) : null;
    const problem = await new Promise(resolve => {
      child.once('spawn', () => resolve(null));
      child.once('error', resolve);
    });
    if (problem) return { value: problem.code === 'ENOENT' ? -5 : -3 };
    if (data.piped) child.stdin.on('error', () => {});
    const id = identifier++;
    children.set(id, { child, piped: data.piped, output, report });
    return { value: id };
  }
  const item = children.get(data.id);
  if (!item) return { value: -4 };
  const { child, piped } = item;
  switch (op) {
    case 'identity': return { value: child.pid || -3 };
    case 'active': return { value: finished(child) ? 0 : 1 };
    case 'wait':
      await exited(child);
      return { value: code(child) };
    case 'observe': {
      if (finished(child)) return { value: 1 };
      const observed = await new Promise(resolve => {
        const finish = () => { clearTimeout(timer); resolve(true); };
        child.once('exit', finish);
        const timer = setTimeout(() => {
          child.off('exit', finish);
          resolve(false);
        }, data.milliseconds);
      });
      return { value: observed ? 1 : 0 };
    }
    case 'write':
      if (!piped || child.stdin.destroyed) return { value: -2 };
      return new Promise(resolve => child.stdin.write(data.bytes, error =>
        resolve({ value: error ? -3 : data.bytes.length })));
    case 'seal':
      if (!piped || child.stdin.destroyed) return { value: -2 };
      return new Promise(resolve => child.stdin.end(() => resolve({ value: 0 })));
    case 'read': {
      if (!piped || (data.stream !== 0 && data.stream !== 1))
        return { value: -2 };
      const bytes = await (data.stream ? item.report : item.output).read(data.length);
      return { value: bytes.length, bytes };
    }
    case 'signal': {
      const name = { 1: 'SIGHUP', 2: 'SIGINT', 9: 'SIGKILL',
        15: 'SIGTERM' }[data.signal];
      return { value: name && child.kill(name) ? 0 : -3 };
    }
    case 'close':
      if (!finished(child) && !child.kill('SIGKILL')) return { value: -3 };
      await exited(child);
      children.delete(data.id);
      return { value: 0 };
    default: return { value: -2 };
  }
}
parentPort.on('message', async ({ op, payload, shared }) => {
  try {
    const answer = await handle(op, payload);
    result(shared, answer.value, answer.bytes);
  } catch {
    result(shared, -3);
  }
});
