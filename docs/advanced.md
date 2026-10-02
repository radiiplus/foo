# Chapter 12: Advanced (Bending the Hardware to Your Will)

You have mastered the basics of FOO. You can write safe, readable, and fast applications. But what happens when you need to write a device driver, a game engine, or a piece of code that squeezes every last drop of performance out of a specific CPU?

This is where FOO’s **Advanced** features shine. FOO doesn't hide the hardware from you; it gives you a safe, structured way to talk directly to it.

---

## 1. Compile-Time Execution (`eval`)

In most languages, your code runs *after* the program is built. But in FOO, you can run code *while* the program is being built. This is called **Compile-Time Execution**.

### The Benefit: Zero Runtime Cost
Imagine you need to calculate a massive lookup table, read a configuration file, or format a huge block of text. If you do this at runtime, your app has to waste time doing it every time it starts. 

With `eval`, FOO performs supported work during compilation and stores the
result in the built program. This removes that runtime computation; the stored
result can still occupy space in the executable and memory when loaded.

```foo
eval {
  constant answer is 40 plus 2.
}

-- Instantly prints 42; the addition happened during compilation.
when answer is 42 { display "42". }
```

---

## 2. Custom Allocators (Memory Chefs)

In Chapter 4, we learned about **Regions** (bulk cleanup). But sometimes, you need even more control. Maybe you want a special memory pool for a game engine, or a memory buffer that lives on a specific hardware device.

FOO allows you to create custom **Allocators** (objects that reserve and release memory).

```foo
use memory as memory.

constant arena is memory.arena try.
after { memory.close(arena) fallback nothing. }
constant buffer is memory.allocate(arena, 1024) try.
```

**The Benefit:** You can dictate exactly *where* your memory lives, ensuring
your high-performance app never suffers from fragmentation (free memory broken
into pieces that are hard to reuse) or slow allocation (memory reservation)
delays.

---

## 3. Advanced Standard-Library Controls

The ordinary standard-library calls choose conservative defaults. The same
modules also expose lower-level controls when an application needs to manage a
protocol (the rules systems use to communicate) or operating-system behavior
directly. These controls remain typed and failable (able to return an error);
they do not expose backend-specific (code-generator-specific) handles.

### HTTP client policy

Headers added to a client are sent on subsequent requests until they are
cleared. Redirect limits are explicit, and connection reuse can be disabled for
isolation-sensitive workloads (work that must not share a connection or state).

```foo
use http as http.

constant client is http.client try.
after { http.close(client). }
http.attach(client, "Accept", "application/json") try.
http.attach(client, "X-Request-ID", "build-44") try.
http.redirects(client, 2) try.
http.reuse(client, false).

constant response is http.request(client, "https://example.com/data", "GET", "", 1048576) try.
after { http.release(response). }
constant status is http.status(response).
when status is 200 { display "Request succeeded". }
```

Repeated header names are preserved. This supports fields such as `Set-Cookie`,
but it also means callers must clear credentials before reusing a client for
another trust domain (a system or organization trusted under different rules).

On Windows, the C backend uses WinHTTP and the operating-system certificate
store, so HTTP and HTTPS do not require a separate curl or OpenSSL installation.
Loading an additional PEM file (a text file containing certificates) with
`http.trust` is not supported by WinHTTP and fails with
`CustomTrustUnavailable`; the Zig and POSIX (Unix-compatible operating-system
interface) implementations support explicit certificate files.

### TCP socket policy

```foo
use net.

constant connection is net.connect("127.0.0.1", 9000) try.
after { net.close(connection) fallback nothing. }
net.nodelay(connection, true) try.
net.keepalive(connection, true) try.

constant written is net.push(connection, "request") try.
net.shutdown(connection, "write") try.
```

`send` writes the complete input or fails. `push` performs one operating-system
send and may return a short count. `shutdown` accepts `read`, `write`, or
`both`; it half-closes (disables one direction of) the selected connection but
does not release it.

### File positioning

```foo
use file.
use io as streams.

constant stream is file.open("records.bin", "read") try.
after { streams.close(stream) fallback nothing. }
constant bytes is file.size(stream) try.
file.seek(stream, (0 subtract 16), "end") try.
constant offset is file.position(stream) try.
```

Positions and sizes are byte counts. Seek origins are `start`, `current`, and
`end`. `flush` empties process buffers without closing the stream; it does not
make a power-loss durability promise. `sync` also asks the operating system to
commit the file to stable storage. Durable publication writes and syncs a
temporary stream, closes it, then uses `replace` on the same filesystem. This
is a one-writer protocol: `file` has no lock, exclusive-create, or
compare-and-swap operation. The guarantee is limited by the host filesystem and
storage honoring the operating-system request; see the standard-library file
contract for platform and failure details.
Whole-file binary reads use `readbytes`; release their `sequence of byte` with
`releasebytes`.

Streaming JSON, explicit allocators, atomics (shared operations completed as
one step), task handles, and typed foreign declarations provide the other
advanced systems surfaces. Platform bindings belong in packages and remain
behind an explicit native contract.

---

## 4. Native boundaries

Sometimes, FOO's high-level abstractions just aren't enough. Maybe you need to use a specific CPU instruction, or talk to a legacy C library that has no FOO bindings.

Start with a typed foreign declaration. It keeps the calling convention,
parameters, and result visible to the checker while the implementation remains
in a separately compiled native library.

```foo
extern "C" function add(left integer, right integer) giving integer.
```

Use a verified native contract only when the portable language and foreign API
cannot express the operation. Target-specific assembly belongs inside that
contract, with its target requirements and effects declared at the boundary.

---

## 5. Hardware Tuning (`opt`)

You know FOO automatically optimizes your code for your CPU. But what if you want to build an app for a *very specific* piece of silicon, like an Apple M1 chip or a specific Intel server?

You can use the `-mcpu` flag to tell FOO's `opt` engine exactly what hardware to target.

```sh
# Build for Apple Silicon
foo build -mcpu apple_m1

# Build for a modern Intel/AMD chip with AVX2
foo build -mcpu x86-64-v3
```

**The benefit:** the selected profile permits compatible instructions and
runtime paths. For example, x86-64-v3 enables the measured AVX2 byte-transfer
path. It does not promise that every expression is vectorized.

Runtime hot paths (frequently executed code) use the same target profile. Byte
transfer, sequence transforms, mutable hash lookup, atomics (shared operations
completed as one step), and task backends have named optimization contracts, so
a C or Zig implementation can be replaced without changing FOO source. The
compiler always retains a portable implementation; target-specific code is
selected only for a compatible CPU and build mode.

Run `foo build --explain` to see each selected substrate (low-level service)
and its reason. The exact thresholds and semantic restrictions (limits needed
to preserve program meaning) are in
[Optimization Under the Hood](tuning.md).

---

## Summary: The Advanced Philosophy

FOO believes that you should never be trapped by your language. 
*   Need speed? Use `eval` to bake math into the binary.
*   Need memory control? Use custom allocators.
*   Need protocol control? Use the advanced HTTP, TCP, file, JSON, and task operations.
*   Need a native operation? Use a typed foreign declaration or verified native contract.
*   Need hardware tuning? Use `-mcpu`.

FOO gives you the safety of a high-level language, with the raw power of a low-level systems language. You are never forced to choose.
