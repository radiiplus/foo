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
`read` and `write` for expected UTF-8 text. Use `readbytes` and `writebytes` for
arbitrary binary data; the returned `sequence of byte` is length-aware and must
be released with `releasebytes`. Native path pointers belong behind explicit
foreign declarations rather than a second standard path API.

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
FOO does not currently expose file locks, exclusive creation, or a filesystem
compare-and-swap (replace only if a value is still current). Use one publishing
writer for each store. Several writers otherwise race, and the last successful
replacement wins. `file.remove` does not sync the parent directory, so it does
not promise a deletion that survives sudden power loss.

The module also cannot list a directory. A collector that must rediscover
immutable files after restart needs an application-maintained durable index, or
the caller must supply the candidate paths. `file.flush` only empties process
buffers. Explicit streams currently use length-aware `text` for bounded
transfers; whole-file binary code should prefer `readbytes`.

The `process` module separates direct execution from shell interpretation.
`process.execute(program, arguments)` passes every item in its
`sequence of text` as one argument. `process.run(command)` intentionally
interprets one command through the host shell and should only receive
deliberately constructed shell syntax.

---

## 3. Networking and Web (`net`, `http`)

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
`Codec[T]` when the application needs a specific FOO record type.

```foo
use json as documents.

constant source is "{ \"name\": \"vibes\", \"level\": 99 }".
constant value is documents.parse(source) try.
after { documents.release(value). }
constant encoded is documents.write(value) try.
display encoded.
```

The JSON module works with a document tree. Use `Codec[T]` when an application
needs to carry a typed encoder and decoder together:

```foo
use codec as codecs.

define Token as record { value of type text. }.
function encode(token Token) giving failable text { give token.value. }
function decode(source text) giving failable Token { give Token(source). }

constant codec is codecs.Codec[Token](encode, decode).
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
into runtime-managed storage. Define and pass an explicit `Codec[T]` when field names,
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

---

## 5. Cryptography (`crypto`)

Cryptography means protecting information with mathematical methods. Hashing
creates a one-way fingerprint; encryption scrambles data so only an authorized
reader can restore it.

FOO's `crypto` module provides hashing (turning data into a fixed-size
fingerprint) and encryption (making data unreadable without the required key).
The C backend uses libsodium headers and its static library at build time. On
Debian and Ubuntu, FOO downloads and caches `libsodium-dev` automatically when
the dependency is missing; no system installation or administrator access is
required. The Zig backend uses Zig's cryptography library.

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
working apt package metadata and network access. On other systems, install the
development files or supply their include and library paths explicitly.

**Available Algorithms:**
*   **Hashing:** SHA-256 through `crypto.hash`.
*   **Encryption:** XChaCha20-Poly1305 through `crypto.seal` and `crypto.open`.
*   **Signatures:** Ed25519 through `crypto.sign` and `crypto.verify`.
*   **Passwords:** Argon2id through `crypto.password` and `crypto.confirm`.

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

`file.handle(stream)` and `net.handle(connection)` expose borrowed operating-system handles for native calls. They return file descriptors and socket descriptors on POSIX, or a Win32 `HANDLE` and Winsock `SOCKET` on Windows. Keep the FOO resource open while using its handle, synchronize native and FOO operations on it, and leave closing to the FOO resource owner.

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
