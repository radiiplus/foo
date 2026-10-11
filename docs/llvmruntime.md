# LLVM runtime migration

Work takes place on `llvm-runtime-batch4` in `.artifacts/batch4-worktree` while
the other LLVM task continues in the main checkout. Do not purge that worktree.
The [runtime ABI](../specs/llvm-runtime-abi.md) documents pointer marshalling,
native callbacks, resource ownership, error identity and ordering contracts.

## Prerequisites

The verified host is Windows x64 with Nim 2.2.12, Node 22.13 or later,
Clang/LLD 18.1.3 and the MSVC x64 libraries/Windows SDK. Keep the checkout's
`vendor/libsodium/windows-x64`, `vendor/zlib/windows-x64`, `vendor/blake3/c`
and `vendor/vulkan` directories intact. Crypto uses the existing sodium/BLAKE3
providers; compression uses zlib. GPU uses bundled Vulkan headers and volk,
with a working Vulkan driver required for actual device execution.
There is no OpenCL source compiler dependency. LLVM host cross-compilation,
runtime-free/startup/interrupt/naked modes remain unqualified and fail explicitly.

## Reproduce

From the worktree root:

```powershell
node tools/native.mjs
nim c -r --cc:clang --path:. --nimcache:.artifacts/ffi-nimcache --out:.artifacts/ffi-test.exe test/backend/llvm/ffi.nim
.artifacts/native/foo.exe test test/library/services.iv --backend llvm --explain --no-batching
.artifacts/native/foo.exe test test/library/device.iv --backend llvm --explain --no-batching
```

The FFI gate verifies LLVM IR and executes aggregate native calls/callbacks
at O0/O2, asserting exit code 42 and reciprocal LLVM gates in the emitted IR.
All language control flow remains LLVM. Explicit native contracts and the
existing runtime providers are compiled using Clang's native ABI.

Each build retains `main.ll`, `verified.ll`, `typed-ir.json`, `llvm.json`,
per-stage command/diagnostic files and `io-batches.json` in its existing artifact
directory. Test outputs are under `test/library/.artifacts/test/llvm/<mode>/`.
The actual Clang target triple/data layout, tool versions and ABI version are
recorded in diagnostics/cache identity.

## Current evidence

The following existing suites have passed with LLVM on this Windows host:
`services` (files, directories, streams, DNS, network interfaces, sockets,
processes, clocks, threads, task callbacks and native failure injection),
`clocks`, `virtual`, `mapping`, `ring`, `crypto`, `compression`, `cancellation`,
`simd`, `resource`, `timer` and `atomic`. This is suite execution evidence;
it does not certify every service operation or every required acceptance case.
The vector implementation preserves ordered scalar operations and checked
integer failures. No SIMD performance specialization is claimed.

`device` passes its two existing tests, but their bodies are conditional on
GPU availability. That result alone does not prove hardware dispatch,
barriers/atomics/subgroups or portability behavior on a Vulkan device.

I/O currently remains synchronous. The effect report identifies consecutive
same-register stream writes, retains their source/result slots, and rejects
every candidate while differential/partial-write and paired benchmark gates
are pending. Every intervening instruction and basic-block boundary is a
barrier. `--no-batching` or `FOO_IO_BATCHING=off` selects the baseline;
attempting to enable an unqualified path is an actionable error. There are no
formed batches, measured thresholds or speedup claims yet.

## Outstanding Batch 4 gates

Linux/macOS LLVM execution and an io_uring runtime probe/fallback;
runtime-free/hardware/startup/interrupt/naked lowering with direct assembly;
unconditional GPU execution/capability tests; complete success/failure,
ownership/cleanup/ordering/platform coverage for every audited service family;
paired batching benchmarks and differential crash/failure tests; and the
complete C/Zig regression suite. Batch 4 is not complete until those gates pass.
