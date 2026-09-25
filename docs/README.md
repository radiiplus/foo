# The FOO Book 📖
### Your Guide to the Systems Language That Reads Like English

Welcome to the official documentation for **FOO**. 

For decades, programmers have been forced to choose: write code that is easy to read (like Python), or write code that is blazing fast and controls the hardware (like C or Rust). **FOO ends that compromise.**

FOO is a "sentence-like" systems language. It uses a brilliant parser to understand natural English phrases, eliminating the "symbol soup" of semicolons and brackets. But underneath the hood, it translates your code into hyper-optimized native machine code. 

This book will take you from your very first line of code to writing advanced, hardware-tuned systems applications.

---

## 🚀 Hello World

Top-level statements run directly. Fallible operations use `try` to propagate
failure or `fallback` to recover locally.
```foo
display "Hello, world!".
```

---

## 💪 Why Read This Book? (The FOO Superpowers)

As you read through these chapters, keep an eye out for the core superpowers that make FOO unique:

*   **🧠 The Parser:** Learn how to write logic that reads like a book (`when x greater than or equal to 10` instead of `if (x >= 10)`).
*   **🏎️ Multiple Backends:** Discover how FOO translates your code into **C11** (for universal compatibility) or **Zig** (for cutting-edge speed).
*   **⚡ Hardware Optimization (`opt`):** See how FOO automatically tunes your math to use **AVX** vector instructions on Intel chips or **NEON** on ARM chips.
*   **🛡️ Bulletproof Safety (Sealing):** Learn how FOO mathematically tracks your memory to eliminate invisible bugs before your app even runs.
*   **🪄 Compile-Time Magic (`eval`):** Learn how to run heavy math and logic *while the program is being built* for zero runtime cost.
*   **🤝 Interoperability:** See how easily FOO talks to the massive, decades-old ecosystem of C libraries.
*   **🔧 Progressive control:** Start with concise file, HTTP, JSON, and task APIs, then opt into headers, sockets, allocators, atomics, and OS-specific controls when needed.
*   **📦 Direct packages:** Add registry packages by name, or use a URL or local path without exposing registry internals in application manifests.

---

## 🗺️ The Journey (Table of Contents)

Read this book from the beginning when learning FOO, or use the chapter links as a reference when you are building.

1.  **[Introduction](intro.md)** — The problem FOO is designed to solve, and why the world needs a sentence-like systems language.
2.  **[Getting Started](start.md)** — Install the toolchain, create your first project in 60 seconds, and run your first app.
3.  **[The Language](language.md)** — Master variables, functions, `match/case` decisions, loops, and bulletproof error handling (`try`/`fallback`).
4.  **[Data and Memory](memory.md)** — Understand records, **Regions** (bulk memory cleanup), and how **Sealing** keeps your RAM safe.
5.  **[Systems](systems.md)** — Talk to files, networks, and the operating system. Learn how to call C code directly from FOO.
6.  **[Concurrency](concurrency.md)** — Do multiple things at once safely using lightweight Tasks, heavy Threads, and Channels.
7.  **[The Standard Library](library.md)** — Explore the "batteries included" modules: JSON, Cryptography, HTTP, and Time.
8.  **[Packages](packages.md)** — Manage dependencies, lockfiles, and publish your own libraries to the world.
9.  **[The Compiler](compiler.md)** — Peek under the hood at the IR (Intermediate Representation), the Build Planner, and the C/Zig backends.
10. **[Platforms](platforms.md)** — Master cross-compilation. Build for Windows, Mac, Linux, ARM, and WebAssembly from a single machine.
11. **[Reference](reference.md)** — The quick cheat-sheet of all FOO commands and keywords.
12. **[Advanced](advanced.md)** — Unlock compile-time execution (`eval`), custom memory allocators, and inline assembly.
13. **[Syntax Guide](syntax.md)** — The complete dictionary of every single sentence structure FOO supports.

---

## 🧠 Words You May Meet

We try to use plain English everywhere, but here is a quick glossary of systems-programming words you will encounter in this book:

| Word | Plain Meaning |
| :--- | :--- |
| **Value** | A piece of information, like `42` or `"hello"`. |
| **Type** | The "shape" of the information (e.g., text vs. integer). FOO checks these strictly. |
| **Scope** | The part of a program where a variable name is visible and alive. |
| **Pointer** | A value that holds the memory address of another value. |
| **Region** | A "bucket" of memory that FOO cleans up all at once, preventing memory leaks. |
| **Backend** | The engine (C or Zig) that turns FOO sentences into runnable machine code. |
| **Native** | Code that speaks directly to the computer's physical hardware or operating system. |
| **Cache** | Saved compiler work that lets your next `foo build` finish instantly. |

---

### Ready to begin? 
Head over to **[Chapter 1: Introduction](intro.md)**, or jump straight to **[Chapter 2: Getting Started](start.md)** to write your first line of code!
