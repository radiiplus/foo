# Chapter 5: Systems (Talking to the Real World)

FOO isn't just for crunching numbers; it's built to interact with the world around it. Whether you need to read a file, download data from the internet, or talk directly to a piece of hardware, FOO has a dedicated "Systems" layer that makes these complex operations feel like simple English sentences.

Let’s look at how FOO connects to the outside world.

---

## 1. Files and Input/Output (The `io` Module)

The simplest way to talk to the operating system is through the `io` module. Because FOO is a **Systems Language**, these operations are designed to be fast and safe, using the OS's native file handling capabilities.

### Reading a File
FOO makes reading an entire file into memory a single, safe operation.
```foo
use file.

-- try propagates the error if the file is missing.
constant content is file.read("notes.txt") try.
display content.
```

### Writing to a File
Writing is just as simple. FOO handles opening the file, writing the bytes, and closing it automatically.
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

FOO was built with the modern web in mind. The `net` module abstracts away the complex world of sockets and TCP/IP, giving you clean, high-performance networking.

**The Benefit:** FOO automatically detects your operating system (Windows, Mac, or Linux) and uses the fastest possible event system (`iocp`, `kqueue`, or `epoll`) under the hood. You write the code once; it runs at maximum speed everywhere.

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

constant exitCode is process.run("ping example.com") try.

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
-- Declare a C ABI function. Use generated bindings for pointer conversion.
extern "C" function puts(value pointer to byte) giving integer.
```

### The `foo bind` Tool
If you have a massive C header file (`.h`), you don't have to type out all the declarations manually. FOO comes with a `bind` tool that reads the C file and automatically generates the FOO bindings for you.

```sh
foo bind my_library.h
```

---

## 5. Going Native: `native c` and `asm`

When you need absolute, raw control over the hardware—like writing a device driver or a highly optimized math routine—FOO allows you to drop down to the metal without leaving your FOO file.

### Native C Blocks
You can write raw C code directly inside a FOO function.
```foo
native c function addIntegers(a integer, b integer) giving integer {
  // This is raw C code
  return a + b;
}
```

### Inline Assembly
For the truly brave, FOO supports inline assembly (`asm`). This is used for extremely specific hardware instructions.
```foo
asm {
  // Raw assembly instructions go here
}
```
*Note: This is an advanced feature used only when standard FOO code isn't fast enough!*

---

## Summary: The Systems Philosophy

FOO’s systems layer is designed to be **Progressive**. 
*   Most of the time, use the high-level `io`, `file`, `net`, `http`, and `process` operations.
*   For protocol and resource control, use their advanced operations such as HTTP client headers, partial TCP sends, half-close, socket options, and file positioning.
*   Use native bindings or explicit `native` blocks only when the portable runtime contract does not expose the required facility.

You are never forced into a "walled garden." FOO gives you the keys to the entire computer.

In the next chapter, we will look at **Concurrency**, where we will learn how to do multiple things at once without crashing!
