<p align="center">
  <img src="assets/dark.svg" alt="FOO logo" width="96" height="96">
</p>

<h1 align="center">FOO</h1>

<p align="center">Readable systems programming with sentence-like syntax and native output.</p>

### The systems language that reads like English and runs like lightning. ⚡

For too long, programmers have been forced to make a choice: Do you want a language that is easy to read (like Python), or do you want a language that is blazing fast and gives you total control over the hardware (like C or Rust)?

**FOO ends that compromise.**

FOO is a "sentence-like" systems language. It uses a brilliant parser to understand natural English phrases, eliminating the "symbol soup" of semicolons and brackets. But underneath the hood, it translates your code into hyper-optimized native machine code via C and Zig backends.

---

## 🚀 Hello, World

Most programs can execute statements directly. Put `try` after a fallible
operation to propagate its error, or use `fallback` to recover locally.
```foo
display "Hello, world!".
```
---

## 💪 Why FOO? (The Superpowers)

FOO is packed with features that make it unique in the programming world:

### 🧠 The Parser: Reads Like a Book
FOO understands natural language. Instead of `if (x >= 10 && y != 0)`, you write:
```foo
when x greater than or equal to 10 and y is not 0 { ... }
```
Instead of `x = x + 1`, you write:
```foo
set x to x plus 1.
```
Your code becomes self-documenting.


### 🏎️ Multiple Backends: C & Zig
FOO acts as a master translator. It can generate standard **C11** code (for universal compatibility) or modern **Zig** code (for cutting-edge speed). You write FOO once, and it runs on Windows, Mac, Linux, ARM, and even WebAssembly.

### ⚡ Hardware Optimization (`opt`)
FOO’s `opt` engine knows exactly what CPU you are targeting. It automatically tunes your math and memory operations to use **AVX** vector instructions on Intel/AMD chips or **NEON** instructions on ARM chips. You write the code once; FOO shifts gears to match your hardware.

### 🛡️ Bulletproof Safety (Sealing)
Memory bugs are the hardest to find. FOO uses a process called **Sealing** to mathematically track the lifecycle of your memory operations. The compiler guarantees that data is read and written in the exact, perfect chronological order, eliminating entire categories of invisible bugs before your app even runs.

### 🪄 Compile-Time Magic (`eval`)
Why waste time doing heavy math or reading config files every time your app starts? With `eval` blocks, FOO does that work *while the program is being built*. The results are baked directly into the final binary, giving you instant startup times and zero runtime cost.

### 🤝 Interoperability
The world runs on C. FOO can read C header files and automatically generate safe, English-like wrappers. You get to use the massive ecosystem of C libraries, but you get to write your app in beautiful FOO.

### 🔧 Progressive Standard Library
Begin with compact `file`, `http`, `json`, and `task` operations. When a system
needs more control, the same modules expose headers, redirects, partial socket
sends, file positioning, streaming JSON, explicit allocators, atomics, dynamic
libraries, and OS-specific facilities without leaking backend handles.

### 📦 Packages Without Registry Syntax
Use `foo add package` or `foo add package@version` for registry dependencies.
Pass a URL or local path as the second argument for external code, then run
`foo install` to resolve and lock the complete dependency graph.

---

## 🛠️ Quick Start

FOO is distributed as a standalone binary. No complex package managers required.

1.  **Install:** Download the installer for your OS from the [Releases](https://github.com/radiiplus/foo/releases) page. Linux PCs use `foo-amd64.deb`; ARM64 Linux devices use `foo-arm64.deb`.
2.  **Verify:** Run `foo doctor` to ensure your toolchain is ready.
3.  **Create:**
    ```sh
    foo new my-app
    cd my-app
    ```
    To use an existing directory, change into it and run `foo new .`.
4.  **Run:**
    ```sh
    foo run
    ```

Ubuntu running through Termux/proot on an ARM64 Android device uses `foo-arm64.deb`. Inside Ubuntu, confirm `uname -m` reports `aarch64`, then install it with `sudo apt install ./foo-arm64.deb`. The package targets Ubuntu's glibc environment, not Termux's Android environment, so run `foo` from the Ubuntu session.

### Uninstall

On Windows, open **Settings > Apps > Installed apps**, choose **FOO**, and
select **Uninstall**. The FOO Start Menu group also includes an uninstall
shortcut. On Ubuntu or Debian, run:

```sh
sudo apt remove foo
```

Uninstalling removes the compiler, its system-managed backend, and installer
PATH changes. It does not remove FOO projects or per-user data under `~/.foo`.

---

## 💻 Editor Support (VS Code)

Write FOO in your favorite editor with first-class support! The official **FOO extension for Visual Studio Code** provides beautiful syntax highlighting, real-time error checking (via the Language Server Protocol), auto-completion, and one-click code formatting.

👉 **[Install the FOO VS Code Extension](https://marketplace.visualstudio.com/items?itemName=radiiplus.foo-iv)**

Get red squiggly lines for type mismatches, hover tooltips for function signatures, and instant formatting just by saving your file.

---

## 📚 Documentation

Ready to learn more? The [FOO Book](docs/README.md) is the best place to start. It will take you from your first "Hello World" to advanced systems programming, step-by-step.

Release history is maintained in the [changelog](CHANGELOG.md).
