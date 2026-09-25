# Chapter 12: Advanced (Bending the Hardware to Your Will)

You have mastered the basics of FOO. You can write safe, readable, and fast applications. But what happens when you need to write a device driver, a game engine, or a piece of code that squeezes every last drop of performance out of a specific CPU?

This is where FOO’s **Advanced** features shine. FOO doesn't hide the hardware from you; it gives you a safe, structured way to talk directly to it.

---

## 1. Compile-Time Execution (`eval`)

In most languages, your code runs *after* the program is built. But in FOO, you can run code *while* the program is being built. This is called **Compile-Time Execution**.

### The Benefit: Zero Runtime Cost
Imagine you need to calculate a massive lookup table, read a configuration file, or format a huge block of text. If you do this at runtime, your app has to waste time doing it every time it starts. 

With `eval`, FOO does the math *during compilation* and bakes the result directly into the final executable. Your app starts instantly and uses zero extra memory.

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

FOO allows you to create custom **Allocators**.

```foo
use memory.

constant arena is memory.arena() try.
after { memory.close(arena) fallback nothing. }
constant buffer is memory.allocate(arena, 1024) try.
```

**The Benefit:** You can dictate exactly *where* your memory lives, ensuring your high-performance app never suffers from fragmentation or slow allocation delays.

---

## 3. Advanced Standard-Library Controls

The ordinary standard-library calls choose conservative defaults. The same modules also expose lower-level controls when an application needs to manage protocol or operating-system behavior directly. These controls remain typed and fallible; they do not expose backend-specific handles.

### HTTP client policy

Headers added to a client are sent on subsequent requests until they are cleared. Redirect limits are explicit, and connection reuse can be disabled for isolation-sensitive workloads.

```foo
use http.

constant client is http.client() try.
after { http.close(client). }
http.addHeader(client, "Accept", "application/json") try.
http.addHeader(client, "X-Request-ID", "build-44") try.
http.redirects(client, 2) try.
http.reuse(client, false).

constant response is http.request(client, "https://example.com/data", "GET", "", 1048576) try.
after { http.release(response). }
constant responseStatus is http.status(response).
when responseStatus is 200 { display "Request succeeded". }
```

Repeated header names are preserved. This supports fields such as `Set-Cookie`, but it also means callers must clear credentials before reusing a client for another trust domain.

On Windows, the C backend uses WinHTTP and the operating-system certificate store, so HTTP and HTTPS do not require a separate curl or OpenSSL installation. Loading an additional PEM file with `http.trust` is not supported by WinHTTP and fails with `CustomTrustUnavailable`; the Zig and POSIX implementations support explicit certificate files.

### TCP socket policy

```foo
use net.

constant connection is net.connect("127.0.0.1", 9000) try.
after { net.close(connection) fallback nothing. }
net.nodelay(connection, true) try.
net.keepalive(connection, true) try.

constant written is net.sendSome(connection, "request") try.
net.shutdown(connection, "write") try.
```

`send` writes the complete input or fails. `sendSome` performs one operating-system send and may return a short count. `shutdown` accepts `read`, `write`, or `both`; it half-closes the selected direction but does not release the connection.

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

Positions and sizes are byte counts. Seek origins are `start`, `current`, and `end`. `flush` explicitly commits buffered output without closing the stream.

Streaming JSON, explicit allocators, atomics, dynamic libraries, task handles, and the target-specific `os.unix` and `os.windows` modules provide the other advanced standard-library surfaces.

---

## 4. Native C and Assembly (The Escape Hatch)

Sometimes, FOO's high-level abstractions just aren't enough. Maybe you need to use a specific CPU instruction, or talk to a legacy C library that has no FOO bindings.

FOO gives you an **Escape Hatch**. Native code always lives in an explicitly marked `native c { ... }`, `native c function`, or `asm { ... }` container, so it cannot be mistaken for FOO source.

### Native C
```foo
native c function addIntegers(a integer, b integer) giving integer {
  return a + b;
}
```

### Inline Assembly
```foo
asm {
  /* Raw assembly instructions go here. */
}
```

**The Benefit:** You can write 99% of your app in safe, readable FOO, and the remaining 1% in raw, high-performance C or Assembly, all in the same file.

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

**The Benefit:** FOO will automatically generate vector instructions, tune memory alignment, and optimize math operations to match the exact physical wiring of your target CPU.

Runtime hot paths use the same target profile. Byte transfer, sequence transforms, mutable hash lookup, atomics, and task backends have named optimization contracts, so a C or Zig implementation can be replaced without changing FOO source. The compiler always retains a portable implementation; target-specific code is selected only for a compatible CPU and build mode.

---

## Summary: The Advanced Philosophy

FOO believes that you should never be trapped by your language. 
*   Need speed? Use `eval` to bake math into the binary.
*   Need memory control? Use custom allocators.
*   Need protocol control? Use the advanced HTTP, TCP, file, JSON, and task operations.
*   Need raw power? Use `native c` or `asm`.
*   Need hardware tuning? Use `-mcpu`.

FOO gives you the safety of a high-level language, with the raw power of a low-level systems language. You are never forced to choose.
