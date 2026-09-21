# Platforms

Targets are named presets such as `linux-x64`, `windows-arm64`, `macos-arm64`, `wasm32-wasi`, and freestanding machine targets. `foo build --target target` selects one without changing source.

Permissions are cumulative: `base < system < machine < hardware`. Base programs use normal language and library features. System adds operating-system and memory services. Machine adds assembly and processor controls. Hardware adds device registers, interrupts, packed data, and vector math.

Windows users who need hardware or freestanding targets run FOO inside WSL 2; hardware simulation may also need QEMU. The same FOO source can target Linux, macOS, Windows, WASI, and supported embedded computers.

When building for another computer, FOO checks that the selected tools really target that computer before joining the final program. It runs a program only when the current computer can run it; otherwise it gives you the file to copy to the target. WASI programs can run under Wasmtime. A freestanding program supplies its own start point and does not assume an operating system.

## Choosing a permission

Start with `base`. Ask for `system` when you need operating-system calls or a custom allocator. Ask for `machine` when you need registers or assembly. Ask for `hardware` when you need device memory or interrupts. A higher level permits more kinds of work; it does not automatically make a program faster.

## Choosing a target

```sh
foo build --target linux-x64
foo build --target windows-arm64
foo build --target wasm32-wasi
```

The source stays the same. Only the final implementation changes. If the target cannot run on the current computer, `foo build` still creates the file and tells you where it is.

## Windows and WSL

Normal Windows programs can be checked and built from a Windows terminal. Hardware and freestanding work uses WSL 2 because those tools run in a Linux environment. Install QEMU inside WSL when you need to simulate a board. `foo doctor` tells you exactly which part is missing.

## Portable design

Give a library operation a portable path first. Put target-specific work behind a small native function. This keeps the rest of the program readable and gives other targets a clear alternative.
