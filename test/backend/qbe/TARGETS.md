# QBE Target Gates

Run focused tests for every target and mode affected by a backend change. Use
`FOO_QBE`, `FOO_QBE_TCC`, and `FOO_WAT2WASM` to select the qualified tools.
Build QBE from `vendor/qbe` with `node tools/qbe/build.mjs` on Windows x64 or
`node tools/qbe/linux/build.mjs --target x64` on Linux x64. Cross-build the
AArch64 host executable with `node tools/qbe/linux/build.mjs --target arm64`.
Build ARM64-host TinyCC with `node tools/tcc/linux/build.mjs` and static GNU
`as` with `node tools/binutils/linux/build.mjs` after obtaining the pinned
source package. Run `node test/backend/qbe/scripts/arm64-toolchain.mjs` with
`FOO_QBE_QEMU_AARCH64` set to QEMU user mode to check native QBE, assembly,
TinyCC archive/link, and static execution.
The Windows build uses the vendored TinyCC source through
`node tools/tcc/build.mjs`.
Set `FOO_QBE_QEMU_AARCH64` to a QEMU user-mode executable to run the AArch64
QBE target probe during the cross-build; the ELF machine check always runs.
Record the selected versions and artifact hashes with the result.

| Path | Gate |
| --- | --- |
| Hosted Windows x64 | `node tools/qbe/hosted/verify.mjs --compiler PATH --target windows-x64` and `node tools/qbe/shared/verify.mjs --compiler PATH --tcc PATH` |
| WASI and threads | `nim r --cc:clang test/backend/qbe/wasm.nim` with WABT and Node available |
| Freestanding ELF | `nim r --cc:clang test/backend/qbe/freestanding/release.nim` and the architecture-specific QBE tests with target assemblers and QEMU |
| UEFI x64 | `node test/backend/qbe/scripts/uefi-boot.mjs` with OVMF available |
| RISC-V board | `node test/backend/qbe/riscv/board.mjs` with QEMU available |

For shared compiler behavior, run `node test/native/run.mjs --filter=backend/qbe`
and `node test/matrix.mjs --backends qbe` on the relevant host. Inspect the
generated IL, WAT, native objects and runtime results before attributing a
performance difference to a lowering change. Hardware and SDK dependent gates
remain unqualified when their runner is unavailable.
