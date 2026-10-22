import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';

let instance;
let written = [];
({ instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {
  wasi_snapshot_preview1: {
    foreign_add: (left, right) => left + right,
    fd_write: (fd, vectors, count, result) => {
      assert.equal(fd, 1);
      assert.equal(count, 1);
      const memory = new DataView(instance.exports.memory.buffer);
      const address = memory.getUint32(vectors, true);
      const size = memory.getUint32(vectors + 4, true);
      written = [...new Uint8Array(instance.exports.memory.buffer, address, size)];
      memory.setUint32(result, size, true);
      return 0;
    },
    fd_read: (fd, vectors, count, result) => {
      assert.equal(fd, 0);
      assert.equal(count, 1);
      const memory = new DataView(instance.exports.memory.buffer);
      const address = memory.getUint32(vectors, true);
      assert.equal(memory.getUint32(vectors + 4, true), 1);
      memory.setUint8(address, 42);
      memory.setUint32(result, 1, true);
      return 0;
    },
    clock_time_get: (clock, precision, result) => {
      assert.equal(clock, 1);
      assert.equal(precision, 1n);
      new DataView(instance.exports.memory.buffer).setBigUint64(result, 42n, true);
      return 0;
    },
    random_get: (address, length) => {
      assert.equal(length, 1);
      new DataView(instance.exports.memory.buffer).setUint8(address, 42);
      return 0;
    },
    path_open: (directory, flags, path, length, openFlags, rights,
      inheritedRights, fdFlags, result) => {
      assert.equal(directory, 3);
      assert.equal(flags, 0);
      assert.equal(length, 1);
      assert.equal(new DataView(instance.exports.memory.buffer).getUint8(path), 65);
      assert.equal(openFlags, 0);
      assert.equal(rights, 0n);
      assert.equal(inheritedRights, 0n);
      assert.equal(fdFlags, 0);
      new DataView(instance.exports.memory.buffer).setUint32(result, 7, true);
      return 0;
    },
    fd_seek: (fd, offset, whence, result) => {
      assert.equal(fd, 7);
      assert.equal(offset, 42n);
      assert.equal(whence, 0);
      new DataView(instance.exports.memory.buffer).setBigUint64(result, offset, true);
      return 0;
    },
    fd_close: fd => {
      assert.equal(fd, 7);
      return 0;
    },
  },
  env: {
    host_add: (left, right) => left + right,
    host_pair: (output, input) => {
      const memory = new DataView(instance.exports.memory.buffer);
      memory.setInt32(output, memory.getInt32(input, true), true);
      memory.setInt32(output + 4, 22, true);
      memory.setInt32(input, 99, true);
    }
  }
}));

for (const name of ['stack_roundtrip', 'byte_roundtrip', 'foreign_call',
  'static_roundtrip',
  'c_foreign_call', 'foreign_aggregate', 'aggregate_call',
  'nested_record', 'multiply32', 'multiply64', 'divide32',
  'wasi_read', 'wasi_clock', 'wasi_random', 'wasi_file']) {
  const expected = ['multiply64', 'wasi_clock', 'wasi_file'].includes(name) ? 42n : 42;
  assert.equal(instance.exports[name](), expected, name);
}
assert.equal(new DataView(instance.exports.memory.buffer)
  .getInt32(instance.exports.counter.value, true), 42);
assert.equal(instance.exports.wasi_write(), 1);
assert.deepEqual(written, [65]);

let status;
const wasi = await WebAssembly.instantiate(readFileSync(process.argv[3]), {
  wasi_snapshot_preview1: { proc_exit: code => { status = code; } }
});
wasi.instance.exports._start();
assert.equal(status, 42);
for (const name of ['out_of_bounds', 'multiply_overflow32',
  'multiply_overflow64', 'shift_out_of_bounds']) {
  assert.throws(() => instance.exports[name](), WebAssembly.RuntimeError, name);
}
for (let run = 0; run < 1000; run++)
  assert.equal(instance.exports.nested_record(), 42);

console.log('QBE WAT memory, aggregates, imports and WASI release: ok');
