# Platforms

Select a target with `foo build --backend qbe --target NAME`. Hosted native
qualification currently covers Windows x64, Linux x64 and Linux ARM64.
Freestanding x64, ARM64 and RISC-V ELF, UEFI x64, WASI, WASI threads and
WebAssembly freestanding have separate product paths and gates. Shader products
use SPIR-V emission.

Use `--target wasm` for freestanding WebAssembly and `--target wasi` for hosted
WebAssembly. `--target freestanding` selects the host architecture's
freestanding preset; cross builds use `x64-freestanding`,
`arm64-freestanding`, or `riscv64-freestanding` explicitly.

Each target requires matching tools, ABI inputs and, for execution tests, a
compatible runner. A preset alone does not supply an SDK or prove execution.
See [QBE Backend Support](qbe.md) for the supported operations and current
limits, and [`test/backend/qbe/TARGETS.md`](../test/backend/qbe/TARGETS.md)
for the target gates.
