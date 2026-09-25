# Chapter 7: The Standard Library (Batteries Included)

One of the greatest strengths of FOO is its **Standard Library** (`std/`). In many languages, you have to hunt down third-party packages for basic tasks like reading JSON, hashing passwords, or making HTTP requests. 

FOO ships with over 40 highly-optimized, battle-tested modules ready to use out of the box. And because they are part of the core language, they all follow the same strict safety rules and English-like syntax you’ve already learned.

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

## 2. Files and Paths (`file`, `path`)

The `file` module handles reading and writing files, while the `path` module helps you build file paths safely (without worrying about slashes `/` vs backslashes `\`).

```foo
use file.

constant configPath is file.join("data", "config.json") try.
constant content is file.read(configPath) try.
file.write(configPath, content) try.
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
with `read`, and control connection reuse with `reply`. Both levels use the same
runtime contract on the C and Zig backends.

---

## 4. Data Serialization (`json`)

Talking to APIs usually means working with JSON. FOO has a built-in JSON parser and encoder that is both fast and type-safe.

```foo
use json as documents.

constant rawJson is "{ \"name\": \"vibes\", \"level\": 99 }".
constant value is documents.parse(rawJson) try.
after { documents.release(value). }
constant encoded is documents.write(value) try.
display encoded.
```

---

## 5. Cryptography (`crypto`)

Security is serious business. FOO’s `crypto` module wraps industry-standard C libraries to give you secure hashing and encryption with zero configuration. You don't need to be a cryptographer to use safe, modern algorithms.

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

## 6. The "Under the Hood" Superpower: Interoperability

You might be wondering: *"How does FOO implement all these features so quickly?"*

This is where FOO’s **Interoperability** shines. Modules such as `net`, `crypto`, and `file` target stable runtime contracts. Each backend can provide a tuned native implementation while FOO code keeps one portable API.

Bulk copy, task scheduling, networking, and collection storage are selected through backend-neutral runtime contracts. C and Zig provide their own implementations without changing application source.

Advanced users can stay inside those portable contracts while controlling more of the underlying service. `http` exposes persistent request headers, redirect limits, and connection reuse. `net` exposes partial sends, half-close, TCP_NODELAY, and keepalive. `file` exposes flush, byte seeking, position, and size. These are explicit operations on the same handles used by the simpler APIs; no backend object leaks into FOO code.

The transfer contract is used throughout the runtime, including sequences, text, JSON, HTTP buffers, and allocator growth. Release builds choose an AVX2, AArch64, machine, or portable C implementation from the target profile. Zig builds use an overlap-safe block transfer sized for the selected CPU.

`sequence.map` allocates its result once. `sequence.filter` and `sequence.dedup`
reserve once and compact once instead of reallocating for each accepted element.
`text.split` counts fields before allocating its result sequence. Deduplication
still performs O(n²) equality comparisons; its allocation and copying work is
O(n).

```foo
use sequence as sequences.

function unique(values sequence of integer) giving fallible sequence of integer {
  give sequences.dedup[integer](values) try.
}
```

For lookup-heavy mutable workloads, use the backend-native open-addressed
`hashmap` with text keys and typed values:

```foo
use hashmap.

constant cache is hashmap.create[integer]() try.
after { hashmap.close[integer](cache) fallback nothing. }
hashmap.put[integer](cache, "answer", 42) try.
constant answer is hashmap.get[integer](cache, "answer") try.
when answer is 42 { display "Cached answer found". }
```

The ordinary `map` remains an immutable, insertion-ordered generic map for code that needs value semantics or non-text keys. `hashmap` is mutable, does not promise iteration order, and shallow-copies values.

---

## Summary: The Library Philosophy

The FOO Standard Library is designed to be **Predictable**. 
*   Operations that can fail return `fallible`; simple queries and releases stay
    infallible when their contracts allow it.
*   Every module uses the same naming conventions.
*   Proven hot-path contracts can select backend and CPU-specific implementations through the `opt` engine.

In the next chapter, we will look at **Packages**, where we will learn how to install libraries from the community and publish our own!
