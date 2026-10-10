# Chapter 7: The Standard Library (Batteries Included)

One of the greatest strengths of FOO is its **Standard Library** (`lib/`, the
modules shipped with the language). In many languages, you have to hunt down
third-party packages for basic tasks like reading JSON, hashing passwords, or
making HTTP requests.

FOO ships standard modules for text, files, networking, data, memory,
concurrency, and development support. They use ordinary FOO declarations and
make failure and resource ownership visible in their signatures.

Let’s tour the most powerful tools in your FOO toolbox.

---

## 1. Text Manipulation (`text`)

Working with strings is a daily task for every programmer. FOO’s `text` module makes it clean and safe.

```foo
use text.

constant sentence is "  Hello, FOO World!  ".
constant clean is text.trim(sentence) try.
after { text.release(clean) fallback nothing. }
display clean.
```

`starts`, `ends`, and `contains` answer common byte-oriented questions without
allocating temporary text. Use `unicode` when an operation must work in Unicode
scalar values rather than UTF-8 bytes.

---

## 2. Files and paths (`file`)

The `file` module reads, writes, opens, and joins ordinary text paths. Use
`read` and `write` for expected UTF-8 text. Use `load` and `save` for
arbitrary binary data; the returned `sequence of byte` is length-aware and must
be released with `file.release`. Native path pointers belong behind explicit
foreign declarations rather than a second standard path API.

  `sequence.view[T](items, offset, count)` returns a read-only subrange without
copying the elements. `memory.bytes(allocator, pointer, size)` returns a
read-only byte view over an existing allocation. Keep the owner alive and do
  not resize or release it while a view is in use; views are not released.

  `file.fetch(stream, offset, destination)` and `file.store(stream, offset,
  source)` transfer bytes at an absolute offset and return the number transferred.
  A short read indicates end of file; callers can retry a partial transfer.
  Open streams in `read`, `write`, or `update` mode as appropriate. Positional operations
  preserve the stream's logical cursor, but mixing cursor-based and positional
  operations concurrently on the same stream is unsupported.

```foo
use file.

constant path is file.join("data", "config.json") try.
constant content is file.read(path) try.
file.write(path, content) try.
```

Use `exists` when absence is ordinary control flow and `kind` when code needs
to distinguish a file, directory, or other filesystem object. `copy` copies a
whole file without promising durable publication. `working` returns the current
working directory as owned text.

For durable publication (making a completed file visible after a restart),
write a temporary stream with `io.write`, call `file.sync`, close it, then call
`file.replace` with a destination on the same filesystem. `file.sync` first
empties FOO's process buffers and then asks the operating system to persist the
open file. On POSIX, a successful replacement also syncs the destination's
parent directory. On Windows, replacement uses the operating system's
write-through move. A successful call means those requests succeeded; it cannot
promise survival on hardware, remote filesystems, or virtual filesystems that
do not honor them. A cross-filesystem replacement fails.

`file.replace` is atomic (readers see the old name or the new name, not a partly
renamed name) only where the local filesystem provides atomic replacement.
FOO does not currently expose a filesystem compare-and-swap (replace only if a
value is still current). Use one publishing
writer for each store. Several writers otherwise race, and the last successful
replacement wins. `file.remove` does not sync the parent directory, so it does
not promise a deletion that survives sudden power loss.

`file.scan` and `file.walk` can enumerate files after restart. A collector must
still define its own naming and recovery rules. `file.flush` only empties process
buffers. Explicit streams currently use length-aware `text` for bounded
transfers; whole-file binary code should prefer `load`.

The `process` module separates direct execution from shell interpretation.
`process.execute(program, arguments)` passes every item in its
`sequence of text` as one argument. `process.run(command)` intentionally
interprets one command through the host shell and should only receive
deliberately constructed shell syntax.
`process.poll(child, milliseconds)` bounds a wait on an owned child and
returns false if it is still running. Zero only checks status; after a true
result, `process.wait(child)` returns the cached exit code.
`process.signal(child, name)` accepts `"kill"` or `"terminate"` on Windows and
POSIX, plus `"interrupt"` or `"hangup"` on POSIX.

---

## 3. Networking and Web (`net`, `dns`, `adapter`, `route`, `http`)

FOO makes web requests incredibly simple. The `http` module handles all the complex TCP/IP and header parsing for you.

```foo
use http as web.

constant client is web.client try.
after { web.close(client). }
constant response is web.request(client, "https://example.com", "GET", "", 1048576) try.
after { web.release(response). }
constant body is web.body(response) try.
display body.
```

The same module exposes the lower-level client lifecycle: create a client,
install a custom trust certificate, choose the method, body, and response limit,
read the status and body separately, then release the response and close the
client. Servers can `listen`, `accept`, inspect `method` and `header`, stream
    with `read`, stop the server with `shutdown`, and control connection reuse
    with `reply`. Both levels use the same
runtime contract on the C and Zig backends.

---

## 4. Data Serialization (`json`)

The `json` module parses text into a checked document tree and writes that tree
back to text. A successfully parsed tree is structurally valid JSON; use
`codec[T]` when the application needs a specific FOO record type.

```foo
use json as documents.

constant source is "{ \"name\": \"vibes\", \"level\": 99 }".
constant value is documents.parse(source) try.
after { documents.release(value). }
constant encoded is documents.write(value) try.
display encoded.
```

The JSON module works with a document tree. Use `codec[T]` when an application
needs to carry a typed encoder and decoder together:

```foo
use codec as codecs.

define Token as record { value of type text. }.
function encode(token Token) giving failable text { give token.value. }
function decode(source text) giving failable Token { give Token(source). }

constant codec is codecs.codec[Token](encode, decode).
constant token is codec.decode("abc") try.
```

For the standard JSON form, `codecs.encode[T]` and `codecs.decode[T]` generate
type-specific code. The portable generated-code set (the set supported by both
native backends) is boolean, signed and unsigned integers, decimal, text,
optional values, sequences, choices, and nested records whose contained values
use the same set. Encoding adopts its
completed output buffer directly instead of copying it into a second managed
buffer. Parsing checks syntax, duplicate and missing fields, JSON value kinds,
and numeric ranges.

Generated codec support is not currently identical for every type:

| Value shape | C backend | Zig backend | Portable application contract |
| --- | --- | --- | --- |
| Boolean, integer, decimal, text | Supported | Supported | Supported |
| Optional values, sequences, choices, and records made only from portable values | Supported recursively | Supported recursively | Supported |
| Pointer, function, or resource fields | Not a generated-code contract | Backend-dependent | Not portable |

Generated sequences, including `sequence of byte`, use JSON arrays. Each byte
is a number from 0 through 255; text uses a JSON string. Optional values use
their value or JSON `null`, and choices use a one-field object whose key is the
active variant.
Payload-free variants use an empty object as their value. Sequences are decoded
into runtime-managed storage. Define and pass an explicit `codec[T]` when field names,
schema versions, validation, unknown-field handling, maximum input size, or a
different ownership policy belongs to the application contract.

### Typed monotonic time

Use raw `current` and `sleep` when an ABI (binary rules shared with other
compiled code) requires nanoseconds. Prefer typed
values in application code:

```foo
use time as clock.

constant delay is clock.millis(50).
constant first is clock.now try.
clock.wait(delay) try.
constant last is clock.now try.
when clock.elapsed(first, last).nanoseconds greater than 0 {
  display "The clock advanced".
}
```

`clock.utc` returns a `stamp` containing UTC/POSIX nanoseconds since
1970-01-01. Persist stamps, not monotonic instants; wall time can move when the
host clock is corrected. `clock.between` returns a duration and fails if its
second stamp precedes its first.

---

## 5. Cryptography (`crypto`)

Cryptography means protecting information with mathematical methods. Hashing
creates a one-way fingerprint; encryption scrambles data so only an authorized
reader can restore it.

FOO's `crypto` module provides hashing (turning data into a fixed-size
fingerprint) and encryption (making data unreadable without the required key).
The C backend uses libsodium headers and its static library at build time.
Windows x64 distributions include both. On Debian and Ubuntu, FOO downloads
and caches `libsodium-dev` automatically when the dependency is missing; no
system installation or administrator access is required. The Zig backend uses
Zig's cryptography library.

**Supported Libraries:**
*   **libsodium:** The C backend's cryptography dependency.
*   **Platform TLS:** WinHTTP and the Windows certificate store on Windows;
    libcurl-backed transport on Linux and macOS.

For C builds, compression uses zlib and HTTP on Linux uses libcurl. On Debian
and Ubuntu, FOO also provisions missing `zlib1g-dev` and
`libcurl4-openssl-dev` into its toolchain cache. When provisioned, C binaries
link the cached libsodium and zlib archives and ship a cached `libcurl.so.4`
beside the executable. `foo doctor` verifies or provisions these dependencies
for native modules imported by local project sources. Provisioning requires
working apt package metadata and network access. On other systems without a
bundled library, install the development files or supply their include and
library paths explicitly.
Windows x64 builds use the bundled static zlib headers and library in
`vendor/zlib`.

`compress.encode` and `compress.decode` transfer arbitrarily long data between
`io.stream` handles using bounded chunks. The wire format has a four-byte
little-endian compressed length before each independent gzip or zlib member;
it is a framed FOO stream rather than a single gzip or zlib file. The decoder
checks each compressed frame and decompressed block against caller limits before
writing it. `compress.pack` and `compress.unpack` retain their single-value
format for interoperability with ordinary gzip and zlib data.

`packing.bits` stores zero/one byte flags least-significant bit first;
`packing.expand(bytes, count)` requires the exact byte length and zero unused
high bits. `packing.runs` stores maximal byte runs as count-byte pairs with
counts from 1 to 255; `packing.unroll(bytes, limit)` rejects malformed pairs
and bounds the expanded byte count. `packing.deltas` encodes nondecreasing
unsigned values as canonical LEB128 differences from zero;
`packing.restore(bytes, limit)` rejects malformed integers and arithmetic
overflow while bounding the decoded item count. Returned sequences own their
storage and must be released with `sequence.release` for their element type.

**Available Algorithms:**
*   **Hashing:** SHA-256 and BLAKE3 over binary input, including incremental updates.
*   **Authentication and key derivation:** HMAC-SHA256 and HKDF-SHA256 over bytes.
*   **Encryption:** XChaCha20-Poly1305 and AES-256-GCM through binary
    `crypto.encrypt` and `crypto.decrypt`; text `crypto.seal` and `crypto.open`
    retain XChaCha20-Poly1305 compatibility.
*   **Signatures:** Ed25519 through `crypto.sign` and `crypto.verify`.
*   **Passwords:** Argon2id through `crypto.password` and `crypto.confirm`.

`crypto.hash` preserves the text-to-hex API. For binary data,
`crypto.hex(bytes)` returns SHA-256 as lowercase hex text and
`crypto.digest(bytes)` returns 32 owned bytes. Release a raw digest with
`sequence.release[byte]` and hex text with `text.release`. Both functions accept arbitrary byte sequences,
including embedded zero bytes.

For large or chunked input, `crypto.begin` creates a SHA-256 `Hasher`.
`crypto.update(state, bytes)` processes each chunk without combining the input.
`crypto.finalize(state)` returns hex text and `crypto.result(state)`
returns 32 owned bytes. Finalization can be repeated and each result is
independently owned. Updates after finalization fail. Call `crypto.close(state)`
once when finished, including on error paths.

`blake.digest(bytes)` returns a 32-byte BLAKE3 digest and `blake.hex`
returns lowercase hex. Use `blake.begin`, `blake.update`, `blake.result` or
`blake.finalize`, and `blake.close` for chunked input. BLAKE3 results are
repeatable without consuming the state; later updates can extend it. C builds
compile the bundled BLAKE3 sources with SSE2 on x86-64 and NEON on AArch64;
Zig uses target-selected vector lanes.

`crypto.encrypt` and `crypto.decrypt` accept `"xchacha20poly1305"` with a
24-byte nonce or `"aes256gcm"` with a 12-byte nonce. Both require a 32-byte
key and return owned binary data. `crypto.available` reports whether an
algorithm can run on the current backend; C's AES-GCM requires CPU support.
Authentication failures return an error and never expose plaintext. Nonces
must be unique for each key. `crypto.protect(key)` stores a 32-byte key in
locked memory; `crypto.encipher` and `crypto.decipher` use it without returning the key,
and `forget` wipes and releases it. If memory locking fails, `protect` fails.
The caller still owns the input byte sequence and must manage that copy.

`crypto.sample(seed, label, size)` provides up to 1 MiB of reproducible
bytes for tests using a 32-byte seed and keyed BLAKE3. It is deterministic and
must not be used for secrets; use `crypto.random` for entropy.

`checksum.compute(bytes)` returns CRC32C for corruption detection. For chunked
input, use `checksum.begin`, `update`, `result`, and `close`. CRC32C does not
provide cryptographic integrity; use `crypto.digest` when an attacker may alter
the data.

For authenticated messages, `crypto.auth(key)` creates an HMAC-SHA256 state.
Feed binary chunks with `crypto.absorb`, then use `crypto.tag` for an owned
32-byte tag or `crypto.check` to verify one. Both finalize the state; call
`crypto.discard` to wipe and release it. `crypto.derive(secret, salt, context,
size)` returns an owned HKDF-SHA256 output of at most 8160 bytes.
`crypto.compare` compares bytes without value-dependent early exit when the
lengths match; the lengths themselves are observable. Release tags and derived
bytes with `sequence.release[byte]`.

```foo
use crypto.

constant secret is "correct horse battery staple".
constant hash is crypto.hash(secret) try.
display "Hash: " plus hash.
```

---

## 6. The "Under the Hood" Superpower: Interoperability (working with other languages)

You might be wondering: *"How does FOO implement all these features so quickly?"*

This is where FOO’s **Interoperability** shines. Modules such as `net`, `crypto`, and `file` target stable runtime contracts. Each backend can provide a tuned native implementation while FOO code keeps one portable API.

Bulk copy, task scheduling, networking, and collection storage are selected
through backend-neutral runtime contracts (rules that do not depend on one code
generator). C and Zig provide their own implementations without changing
application source.

Advanced users can stay inside those portable contracts while controlling more of the underlying service. `http` exposes persistent request headers, redirect limits, and connection reuse. `net` exposes partial sends, half-close, TCP_NODELAY, and keepalive. `file` exposes process-buffer flushing, stable-storage sync, atomic same-filesystem replacement, removal, byte seeking, position, and size. These are explicit operations on the same handles used by the simpler APIs; no backend object leaks into FOO code.

`net.timeout(connection, direction, milliseconds)` and
`net.expiry(socket, direction, milliseconds)` set TCP and UDP send or
receive timeouts. Direction is `"send"` or `"receive"`; zero disables the
timeout. Both return the effective OS value in milliseconds, which may differ
from the request. Values above 2,147,483,647 fail, and a timed-out transfer
currently reports `IoFailure`.

`net.provision(connection, direction, size)` sets a TCP send or receive buffer;
`net.allocation` queries it. Direction is `"send"` or `"receive"`, size is
1..2,147,483,647 bytes, and both return the effective OS capacity rather than
the requested size. `net.lifetime(connection, hops)` sets an IPv4 TTL or IPv6
unicast hop limit from 1 to 255. `net.priority(connection, value)` sets the
IPv4 TOS or IPv6 traffic class from 0 to 255. Both report the effective OS
value; hosts may restrict nonzero traffic classes.

`poll.create` owns a watcher for up to 128 registrations. Register an open TCP
connection or listener with `poll.tcp`, or a UDP socket with `poll.udp`, using
`"receive"` or `"send"` and a unique nonzero token. Socket registrations stay
active until `poll.remove`; readiness can also report a closed or failed peer,
so the subsequent socket operation determines the outcome. `poll.deadline`
registers a one-shot monotonic timer by token. `poll.wait` returns a ready token
or zero when its millisecond timeout expires; zero checks without blocking.
`poll.child` registers an owned child's exit under a token; it remains ready
until removed. Keep that child open while registered. `poll.remove` drops a registration, and `poll.close` releases the watcher
without closing its sockets. Delays and waits above 2,147,483,647 milliseconds
fail. Keep sockets open while registered and serialize poller calls.

`file.open(path, "create")` creates a new file exclusively and opens it for
reading and writing; it fails if the path already exists. `"update"` opens an
existing file for both. `file.truncate(stream, size)` changes its length and
`file.reserve(stream, size)` requests allocation through the given size,
extending the file when needed. Both keep the stream cursor. `file.lock` accepts
`"shared"` or `"exclusive"` for a blocking, advisory whole-file lock; call
`file.unlock` when done. Closing a stream releases its lock. These operations
require a writable stream except a shared lock.

`file.scan(path)` opens a directory cursor. `file.next(cursor)` returns one
entry name in host order and returns empty text at the end; file names cannot
be empty. Release each nonempty name with `text.release`, then close the cursor
with `file.finish`. The cursor skips `.` and `..`.
`file.walk(path)` opens a depth-first recursive cursor. `file.visit` returns
relative paths, yielding each directory before its children and never following
links. Release each nonempty result with `text.release`; call `file.halt`
even when stopping early.
`file.metadata(path)` returns an owned snapshot with size, type (`file`,
`directory`, `link`, or `other`), read-only status, and `modified`, `accessed`,
and `changed` times as UTC nanoseconds since 1970. `changed` is the filesystem
metadata-change time, not creation time. The snapshot describes the link itself
when the path is a link. `file.category` borrows the snapshot; `extent`,
`modified`, `accessed`, `changed`, and `writable` inspect it. `writable` reflects
the read-only attribute or mode bits and does not probe effective access. Close the snapshot
with `file.dismiss`. `file.temporary(directory, prefix)` creates an exclusive
empty file and returns its owned path. The prefix may contain ASCII letters,
digits, `_`, and `-`; remove the file and release the path when finished.
`file.remove` removes files and empty directories. `file.free(path)` reports
bytes available to the process on the containing filesystem, and
`file.block(path)` reports its allocation unit in bytes. Both require an
existing path.

`testing.fault("write", count)` arms a one-shot fault for the current thread.
`file.store` returns at most `count` bytes; `io.write` writes at most `count`
bytes and then fails. `"sync"` fails after flushing process buffers, before the
host sync request; `"replace"` fails before renaming. Pass zero for those two
operations. `testing.clear` disarms a pending fault. These controls are for
deterministic failure tests and do not simulate a sudden process or power loss;
use `process.exit` or `process.abort` for child-process crash tests.

`file.handle(stream)` and `net.handle(connection)` expose borrowed operating-system handles for native calls. They return file descriptors and socket descriptors on POSIX, or a Win32 `HANDLE` and Winsock `SOCKET` on Windows. Keep the FOO resource open while using its handle, synchronize native and FOO operations on it, and leave closing to the FOO resource owner.

`resource.files`, `resource.mapped`, and `resource.threads` report live
FOO-owned file handles, mapped bytes, and thread handles. `resource.tasks`
counts accepted callbacks that have not finished; `resource.pending` counts
callbacks accepted but not yet started. `resource.heap` counts tracked FOO-owned
buffers and explicit memory allocations, excluding native library internals.
All are diagnostic snapshots, not synchronization primitives. Standard input,
output, and error are borrowed handles and are not counted as owned files.

`dylib.open(path)` loads a native shared library. `dylib.lookup(library, name)`
resolves a symbol for the explicit `uint64_t (*)(uint64_t)` C ABI; invoke it
with `dylib.call`, then `dylib.discard` the symbol and `dylib.close` the library.
The caller is responsible for matching the exported C signature. Closing a
library invalidates all symbols obtained from it, and later calls fail.

`bitmap.merge`, `bitmap.intersect`, and `bitmap.difference` combine equal-length
bitmaps and return independently owned results; a length mismatch fails with
`Shape`. `bitmap.rank(value, index)` counts set bits before `index`, allowing
the bitmap length as the final boundary. `bitmap.select(value, ordinal)`
returns the index of a zero-based set bit or null when absent. Both queries
scan the packed words and allocate no storage.
`bitmap.toggle` flips a checked bit; `bitmap.invert` complements logical bits
without setting unused final-word bits. `bitmap.symmetric` keeps bits set in
exactly one of two equal-length inputs. These updates return independent
bitmaps. `bitmap.next(value, from)` includes `from`, while
`bitmap.previous(value, before)` excludes `before`; both return null if no bit
qualifies or the boundary exceeds the bitmap length.

`tree` provides a persistent ordered search structure for `Ord` values.
`rank`, `find`, `lower`, and `nth` use a packed midpoint search in logarithmic
time. `insert` and `remove` return independent values and copy storage in
linear time. Duplicate insertion leaves the set size unchanged.

`set` supports `unite`, `intersect`, `difference`, and `symmetric` over
`Equatable` members. The first result keeps all left members then appends new
right members; intersection and difference keep left order, while symmetric
difference keeps left-only members before right-only members. These results
own their storage and need `set.release`; `set.subset` checks inclusion without
allocating. Membership scans make the algebra O(n × m) comparisons.

`heap.build` and `heap.merge` use bottom-up heapification after copying their
inputs. `heap.replace` changes the minimum of a nonempty heap, and `heap.pop`
returns both the minimum and an independently owned remaining heap. Release
every returned heap with `heap.release`. `heap.sorted` returns an independent
ascending sequence; release it with `sequence.release`.

`file.map(path, offset, length)` opens a read-only mapping; `file.edit` opens a
shared writable mapping of an existing file. `length` zero means the rest of
the file; an empty range or a range beyond the file fails. The offset need not
be page aligned. `file.view(mapping)` borrows read-only bytes and
`file.mutable(mapping)` borrows writable bytes from an edit mapping.
`file.persist(mapping)` requests durable publication of changed pages, and
`file.persist(mapping, offset, length)` requests it for a checked range
relative to the mapped view; zero length does nothing. Both sync the backing
file after flushing pages. They do not identify persistent-memory devices.
`file.unmap(mapping)` flushes writable mappings before releasing them. Finish
using each view before unmapping; the checker rejects a later use of the view.
Do not truncate the file while it is mapped.

`virtual.reserve(size)` reserves a page-rounded region without committing it.
`virtual.commit(region)` makes the whole region readable and writable.
`virtual.protect(region, mode)` accepts `none`, `read`, `write` (read/write), or
`execute` (read/execute). `virtual.decommit` discards committed pages, and a
later commit supplies zero-filled pages. `virtual.load/store` check bounds and
protection before access. Release each region with `virtual.release`.

`memory.reserve(owner, size, alignment)` accepts a nonzero power of two
and retains that alignment when `memory.expand` grows or shrinks the buffer.
`memory.aligned(pointer, alignment)` checks an address, without validating its
ownership or lifetime. `arch.prefetch(bytes, offset)` and
`arch.stage(bytes, offset)` issue advisory read and write cache hints;
out-of-range offsets do nothing. Prefetch does not make an invalid view safe to
access and does not guarantee a cache hit.

Atomic operations accept explicit `relaxed`, `acquire`, `release`, `both`, and
`sequential` orders. `atomic.compare` takes separate success and failure orders;
failure permits only `relaxed`, `acquire`, or `sequential` and cannot require a
stronger order than success. Invalid combinations return `InvalidOrder`.
The typed `atomic.order` choice is accepted by `read`, `write`, `increase`,
`decrease`, `exchange`, `commit`, and `cas`; the original text operations remain
available for existing code.

The transfer contract is used throughout the runtime, including sequences,
text, JSON, HTTP buffers, and allocator growth (expanding reserved memory).
Release builds choose an AVX2, AArch64, machine, or portable C implementation
from the target profile. Zig builds use an overlap-safe block transfer sized
for the selected CPU.

Selection is workload-aware rather than a blanket replacement of system code.
The AVX2 path covers a measured medium-size range, non-overlapping bulk machine
copies may use `rep movsb`, and other transfers retain the platform's
overlap-safe implementation. See [Optimization Under the Hood](tuning.md) for
thresholds, semantic limits, task substrates, cache specialization, and the
benchmark evidence required for new paths.

`sequence.map` allocates its result once. `sequence.filter` and `sequence.dedup`
reserve once and compact once instead of reallocating for each accepted element.
`sequence.merge` combines two ascending sequences in one pass.
`sequence.unique` removes adjacent duplicates from ascending input in linear
time and returns independent storage. For ascending
inputs, `sequence.unite`, `sequence.intersect`, and `sequence.difference` return
sorted, duplicate-free, independently owned results in linear time. Release
each result with `sequence.release`. `sequence.partition`
keeps the order of each side and calls the predicate once per item; release
both `division.kept` and `division.rest` after use. `radix.signed` sorts signed
64-bit values into an independent result, including both signed limits.
`text.split` counts fields before allocating its result sequence. Deduplication
still performs O(n²) equality comparisons (the comparisons can grow with the
square of the item count); its allocation and copying work is
O(n).

```foo
use sequence as sequences.

function unique(values sequence of integer) giving failable sequence of integer {
  give sequences.dedup[integer](values) try.
}
```

For lookup-heavy mutable workloads, use the backend-native open-addressed
`table` (entries stored directly inside the hash table) with text keys and
typed values:

```foo
use table.

constant cache is table.create[integer] try.
after { table.close[integer](cache) fallback nothing. }
table.put[integer](cache, "answer", 42) try.
constant answer is table.get[integer](cache, "answer") try.
when answer is 42 { display "Cached answer found". }
```

The ordinary `map` remains an immutable (unchangeable), insertion-ordered
generic map (one map implementation that works with several types) for code
that needs value semantics (copies behave as independent values) or non-text
keys. `table` is mutable, does not promise iteration order, and shallow-copies
values (inner data may still be shared).

---

## Summary: The Library Philosophy

The FOO Standard Library is designed to be **Predictable**. 
*   Operations that can fail return `failable`; simple queries and releases stay
    non-failable when their contracts allow it.
*   Every module uses the same naming conventions.
*   Proven hot-path contracts (rules for frequently executed code) can select backend and CPU-specific implementations through the `opt` engine.

In the next chapter, we will look at **Packages**, where we will learn how to install libraries from the community and publish our own!
