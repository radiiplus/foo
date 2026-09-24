# Chapter 5: Systems (Talking to the Real World)

FOO isn't just for crunching numbers; it's built to interact with the world around it. Whether you need to read a file, download data from the internet, or talk directly to a piece of hardware, FOO has a dedicated "Systems" layer that makes these complex operations feel like simple English sentences.

Let’s look at how FOO connects to the outside world.

---

## 1. Files and Input/Output (The `io` Module)

The simplest way to talk to the operating system is through the `io` module. Because FOO is a **Systems Language**, these operations are designed to be fast and safe, using the OS's native file handling capabilities.

### Reading a File
FOO makes reading an entire file into memory a single, safe operation.
```foo
use io.

start() {
  -- try ensures we handle the error if the file is missing
  constant content is try file read "notes.txt".
  display content.
  give nothing.
}
```

### Writing to a File
Writing is just as simple. FOO handles opening the file, writing the bytes, and closing it automatically.
```foo
use io.

start() {
  try file write "output.txt" with "Hello, hard drive!".
  give nothing.
}
```

### Reading User Input
You can also read directly from the keyboard.
```foo
use io.

start() {
  display "What is your name?".
  constant name is try io read line.
  display "Nice to meet you, " plus name.
  give nothing.
}
```

---

## 2. Networking (The `net` Module)

FOO was built with the modern web in mind. The `net` module abstracts away the complex world of sockets and TCP/IP, giving you clean, high-performance networking.

**The Benefit:** FOO automatically detects your operating system (Windows, Mac, or Linux) and uses the fastest possible event system (`iocp`, `kqueue`, or `epoll`) under the hood. You write the code once; it runs at maximum speed everywhere.

```foo
use net.

start() {
  -- Connect to a server
  constant socket is try net connect "example.com" with 80.
  
  -- Send a simple HTTP request
  try net send socket "GET / HTTP/1.0\n\n".
  
  -- Receive the response
  constant response is try net receive socket with 1024.
  display response.
  
  give nothing.
}
```

---

## 3. Running Programs (The `process` Module)

Sometimes you need to run an external command, like a database tool or a system utility. The `process` module lets you do this safely.

```foo
use process.

start() {
  -- Run a command and wait for it to finish
  constant result is try process run "ping example.com".
  
  -- Get the arguments passed to your own FOO program
  constant args is try process arguments.
  display args.
  
  give nothing.
}
```

---

## 4. Interoperability: The Superpower (Talking to C)

This is one of FOO's greatest strengths. The programming world runs on C. If there is a library you need—whether for graphics, audio, or cryptography—it is almost certainly written in C.

FOO doesn't make you rewrite it. FOO has built-in **Interoperability** (the ability to talk to other languages seamlessly).

### Calling C Functions
You can declare a C function right inside your FOO code. FOO will link against the C library and call it directly.

```foo
-- Declare a standard C library function
use "c" function printf(fmt of type pointer to byte, ...) of type integer.

start() {
  printf("This message is printed by C, but controlled by FOO!\n").
  give nothing.
}
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
native c function add_ints(a of type integer, b of type integer) of type integer {
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
*   Most of the time, you use the high-level `io`, `net`, and `process` modules because they are safe and easy.
*   When you need more control, you use `use "c"` to call existing libraries.
*   When you need total control, you use `native` blocks.

You are never forced into a "walled garden." FOO gives you the keys to the entire computer.

In the next chapter, we will look at **Concurrency**, where we will learn how to do multiple things at once without crashing!