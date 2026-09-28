# Chapter 5: Systems (Talking to the Real World)

FOO isn't just for crunching numbers; it's built to interact with the world around it. Whether you need to read a file, download data from the internet, or talk directly to a piece of hardware, FOO has a dedicated "Systems" layer that makes these complex operations feel like simple English sentences.

Let’s look at how FOO connects to the outside world.

---

## 1. Files and input/output (`file` and `io`)

Use `file` for whole-file operations and file-backed streams. Use `io` for the
process input, output, and error streams. Operations that can fail return a
failable value and therefore need postfix `try` or a deliberate `fallback`.

### Reading a File
`file.read` reads an entire text file and returns its content on success.
```foo
use file.

-- try propagates the error if the file is missing.
constant content is file.read("notes.txt") try.
display content.
```

### Writing to a File
`file.write` performs the complete write and closes its internal handle before
returning. A write failure is propagated by `try`.
```foo
use file.

file.write("output.txt", "Hello, hard drive!") try.
```

### Reading User Input
You can also read directly from the keyboard.
```foo
use io.

display "What is your name?".
constant name is io.line(io.input()) try.
display "Nice to meet you, " plus name.
```

---

## 2. Networking (The `net` Module)

FOO was built with the modern web in mind. The `net` module abstracts away
(hides the lower-level details of) sockets (operating-system network
connections) and TCP/IP, giving you clean, high-performance networking.

**The benefit:** the target selects IOCP (Windows completion events) on Windows,
kqueue (Apple and BSD readiness events) on Apple and BSD systems, epoll (Linux
readiness events) on Linux, or a threaded fallback elsewhere. These services avoid
one blocked thread per asynchronous socket operation (network work that can
wait without stopping other work) where the platform backend supports event
polling (asking the operating system which operations are ready); no backend is
claimed to be universally fastest.

```foo
use net as network.

-- Connect to a server and guarantee cleanup.
constant socket is network.connect("example.com", 80) try.
after { network.close(socket) fallback nothing. }

constant sent is network.send(socket, "GET / HTTP/1.0\n\n") try.
constant response is network.receive(socket, 1024) try.
display response.
```

---

## 3. Running Programs (The `process` Module)

Sometimes you need to run an external command, like a database tool or a system utility. The `process` module lets you do this safely.

```foo
use process.

constant status is process.run("ping example.com") try.

when process.count() greater than 0 {
  constant first is process.argument(0) try.
  display first.
}
```

---

## 4. Interoperability: The Superpower (Talking to C)

This is one of FOO's greatest strengths. The programming world runs on C. If there is a library you need—whether for graphics, audio, or cryptography—it is almost certainly written in C.

FOO doesn't make you rewrite it. FOO has built-in **Interoperability** (the ability to talk to other languages seamlessly).

### Calling C Functions
You can declare a C function right inside your FOO code. FOO will link against the C library and call it directly.

```foo
-- Declare a C ABI (binary calling rules) function. Use generated bindings for pointer conversion.
extern "C" function puts(value pointer to byte) giving integer.
```

### The `foo bind` Tool
If you have a massive C header file (`.h`), you don't have to type out all the declarations manually. FOO comes with a `bind` tool that reads the C file and automatically generates the FOO bindings (declarations that connect FOO names to C code) for you.

```sh
foo bind library.h
```

---

## 5. Native boundaries

When a portable library operation is not enough, use a typed foreign
declaration or a verified native contract. Keep the boundary small because FOO
cannot prove the behavior of its native implementation.

### Calling C

Declare the ABI and the complete FOO signature:
```foo
extern "C" function add(left integer, right integer) giving integer.
```

`foo bind header.h` generates these declarations for larger C APIs. Assembly
belongs behind a native contract with explicit target and effect requirements;
it is not an ordinary standalone FOO statement.

---

## Summary: The Systems Philosophy

FOO’s systems layer is designed to be **Progressive**. 
*   Most of the time, use the high-level `io`, `file`, `net`, `http`, and `process` operations.
*   For protocol and resource control, use their advanced operations such as HTTP client headers, partial TCP sends, half-close, socket options, and file positioning.
*   Use native bindings or explicit `native` blocks only when the portable runtime contract does not expose the required facility.

You are never forced into a "walled garden." FOO gives you the keys to the entire computer.

In the next chapter, we will look at **Concurrency**, where we will learn how to do multiple things at once without crashing!
