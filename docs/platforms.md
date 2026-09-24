# Chapter 10: Platforms (Build Anywhere, Run Everywhere)

In many ecosystems, building your app for a different operating system means you have to actually *own* a computer running that operating system. If you are on a Mac and want to build a Windows `.exe`, you usually have to boot up a virtual machine or use a clunky third-party tool.

FOO completely shatters this limitation. Because FOO translates your code down to native C or Zig, it supports **Cross-Compilation** out of the box. You can sit on your Mac, type a single command, and generate a lightning-fast executable for Windows, Linux, ARM, or even the Web.

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

Want to build a highly optimized app for a modern Linux server using AVX vector instructions?
```sh
foo build --target linux-x64-v3
```

**The Benefit:** FOO’s `opt` (optimization) engine reads the preset and automatically tunes your math and memory operations to match the exact physical wiring of that specific CPU. 

---

## 2. Cross-Compilation (The Ultimate Flex)

Because FOO manages its own toolchains, cross-compilation is seamless. You do not need to install Windows SDKs or Linux headers on your Mac. 

If you type `foo build --target windows-x64` while sitting on a Linux machine, FOO’s backend will automatically generate standard Windows PE executables (`.exe` files). 

```sh
# Run this on a Mac:
foo build --target windows-x64

# FOO outputs:
# .artifacts/build/my_app.exe
```
You can now copy that `.exe` file to a Windows machine, double-click it, and it will run natively at maximum speed.

---

## 3. WebAssembly (FOO in the Browser)

WebAssembly (WASM) is a technology that allows you to run high-performance, compiled code directly inside a web browser. FOO has first-class support for WASM through the **WASI** (WebAssembly System Interface) preset.

```sh
foo build --target wasi
```

**Why this is awesome:** 
You can write your core business logic (like image processing, cryptography, or game physics) in FOO, compile it to WASM, and drop it into a JavaScript website. Your web app will run at near-native speeds, completely bypassing the slowness of traditional JavaScript.

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

Normally, yes. But FOO has a built-in **Toolchain Manager**. When you run `foo doctor` or attempt a cross-compile, FOO checks its local cache. If it realizes it is missing the specific Zig or C toolchain required for your target, it will quietly download and configure it in the background.

You never have to manually install cross-compilers, linkers, or sysroots. FOO acts as its own IT department.

---

## Summary: The Platform Philosophy

FOO believes that your code should not be held hostage by the computer you happen to be typing on. 

By combining **Target Presets**, **Native Backends (C/Zig)**, and an **Auto-Managing Toolchain**, FOO allows a single developer to ship high-performance, native applications to Windows, Mac, Linux, ARM, RISC-V, and the Web—all from a single command line.

In the next chapter, we will look at the **Reference**, a quick cheat-sheet of all the syntax we've learned!
