# Chapter 7: The Standard Library (Batteries Included)

One of the greatest strengths of FOO is its **Standard Library** (`std/`, the
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

---

## 2. Files and paths (`file`, `path`)

The `file` module reads, writes, opens, and joins ordinary text paths. The
lower-level `path` module works with native pointer-oriented paths at foreign
boundaries; application code normally starts with `file`.

```foo
use file.

constant path is file.join("data", "config.json") try.
constant content is file.read(path) try.
file.write(path, content) try.
```

---

## 3. Networking and Web (`net`, `http`)

FOO makes web requests incredibly simple. The `http` module handles all the complex TCP/IP and header parsing for you.

```foo
use http as web.

constant client is web.client() try.
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
type-specific code for booleans, numbers, text, and nested records. Encoding
adopts its completed output buffer directly instead of copying it into a second
managed buffer. The parser
checks syntax, duplicate and missing fields, JSON value kinds, and numeric
ranges. Use an explicit `Codec[T]` when the application needs different field
names, versions, validation, size limits, or unknown-field policy.

### Typed monotonic time

Use raw `current` and `sleep` when an ABI (binary rules shared with other
compiled code) requires nanoseconds. Prefer typed
values in application code:

```foo
use time as clock.

constant delay is clock.millis(50).
constant first is clock.now() try.
clock.wait(delay) try.
constant last is clock.now() try.
when clock.elapsed(first, last).nanoseconds greater than 0 {
  display "The clock advanced".
}
```

---

## 5. Cryptography (`crypto`)

Cryptography means protecting information with mathematical methods. Hashing
creates a one-way fingerprint; encryption scrambles data so only an authorized
reader can restore it.

Security is serious business. FOO's `crypto` module wraps industry-standard C
libraries to provide hashing (turning data into a fixed-size fingerprint) and
encryption (making data unreadable without the required key) with zero
configuration. You do not need to be a cryptographer to use safe, modern
algorithms.

**Supported Libraries:**
*   **libsodium:** The default backend for modern, high-speed cryptography (NaCl).
*   **Platform TLS:** WinHTTP and the Windows certificate store on Windows;
    libcurl-backed transport on Linux and macOS.

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

Advanced users can stay inside those portable contracts while controlling more of the underlying service. `http` exposes persistent request headers, redirect limits, and connection reuse. `net` exposes partial sends, half-close, TCP_NODELAY, and keepalive. `file` exposes flush, byte seeking, position, and size. These are explicit operations on the same handles used by the simpler APIs; no backend object leaks into FOO code.

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

constant cache is table.create[integer]() try.
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
