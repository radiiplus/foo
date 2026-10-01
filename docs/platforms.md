# Chapter 10: Platforms (Build Anywhere, Run Everywhere)

In many ecosystems, building your app for a different operating system means you have to actually *own* a computer running that operating system. If you are on a Mac and want to build a Windows `.exe`, you usually have to boot up a virtual machine or use a clunky third-party tool.

FOO defines named target presets for Windows, Linux, macOS, WASI, and selected
freestanding environments. A cross-build succeeds when the managed backend and
the project's native dependencies support the requested architecture and ABI.

Let’s look at how FOO conquers the hardware world.

---

## 1. The Magic of Target Presets

To tell FOO what kind of computer you are building for, you use the `--target` flag. But you don't need to memorize complex architecture codes. FOO comes with a list of **Target Presets** (pre-configured shortcuts for the most popular devices on Earth).

Want to build an app for an Apple Silicon Mac?
```sh
foo build --target macos-arm64
```

Want to build an app for a standard Windows PC?
```sh
foo build --target windows-x64
```

Want to allow AVX2-backed runtime paths on a compatible modern Linux server?
```sh
foo build --target linux-x64-v3
```

**The benefit:** the preset (a named group of target settings) records the CPU deployment promise, participates in
cache identity, and enables compatible runtime paths. It does not imply that
every operation is vectorized (performed on several values at once).

---

## 2. Cross-Compilation (The Ultimate Flex)

FOO manages its default Zig toolchain and target catalog. Projects with foreign
libraries or custom native inputs may still need compatible target libraries,
headers, or SDK components.

If you type `foo build --target windows-x64` while sitting on a Linux machine,
FOO's backend (code generator) will automatically generate standard Windows PE
(Portable Executable) files (`.exe` files).

```sh
# Run this on a Mac:
foo build --target windows-x64

# FOO outputs:
# target/app.exe
```
You can now copy that `.exe` file to a compatible Windows machine and run it
natively. A CPU-specific preset still requires the destination CPU features.

---

## 3. WebAssembly (FOO in the Browser)

WebAssembly (WASM, a portable binary format for sandboxed programs) allows
compiled code to run inside a web browser or another compatible host. FOO has
first-class support for WASM through the **WASI** (WebAssembly System Interface,
a standard way for WebAssembly programs to request system services) preset.

```sh
foo build --target wasi
```

The `wasi` preset emits a WASI module for a compatible host. Browser integration
requires the imports and JavaScript glue expected by that host; performance
depends on the workload and runtime.

---

## 4. Bare Metal (Freestanding)

What if you are programming a microcontroller, a custom piece of hardware, or an operating system kernel? These devices don't have Windows or Linux; they have *nothing*. 

FOO supports **Freestanding** targets. This tells the compiler: *"Do not include the standard library, do not expect an operating system, and do not expect a file system."*

```sh
foo build --target riscv64-freestanding
```

This strips FOO down to its absolute bare minimum, generating raw machine instructions that can run directly on silicon. 

---

## 5. The Toolchain Manager (Auto-Magic Setup)

You might be wondering: *"If I am building for Windows, doesn't my compiler need Windows-specific C libraries?"*

Normally, yes. But FOO has a built-in **Toolchain Manager**. Debian installation provisions the pinned Zig backend, while `foo run`, `foo build`, and cross-compilation check the managed cache and install it on demand when necessary. `foo doctor` reports the current state without changing the machine. Clang remains an optional external tool used only for C-header bindings and explicitly selected C builds.

You never have to manually install cross-compilers, linkers (tools that join
compiled pieces), or sysroots (folders containing another target system's
libraries and headers). FOO acts as its own IT department.

---

## Summary: The Platform Philosophy

FOO believes that your code should not be held hostage by the computer you happen to be typing on. 

By combining **Target Presets**, **Native Backends (C/Zig)**, and an **Auto-Managing Toolchain**, FOO allows a single developer to ship high-performance, native applications to Windows, Mac, Linux, ARM, RISC-V, and the Web—all from a single command line.

In the next chapter, we will look at the **Reference**, a quick cheat-sheet of all the syntax we've learned!
