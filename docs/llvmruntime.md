# LLVM runtime migration

Runtime development is retained on `llvm-runtime-batch4` in
`.artifacts/batch4-worktree`. Integration with the updated core is on
`llvm-runtime-batch4-integration` in `.artifacts/batch4-integration`.
Do not purge either worktree while integration is pending.
The [runtime ABI](../specs/llvm-runtime-abi.md) documents pointer marshalling,
native callbacks, resource ownership, error identity and ordering contracts.

## Prerequisites

The Windows qualification host uses Nim 2.2.12, Node 22.13 or later,
Clang/LLD 18.1.3 and the MSVC x64 libraries/Windows SDK. Keep the checkout's
`vendor/libsodium/windows-x64`, `vendor/zlib/windows-x64`, `vendor/blake3/c`
and `vendor/vulkan` directories intact. Crypto uses the existing sodium/BLAKE3
providers; compression uses zlib. GPU uses bundled Vulkan headers and volk,
with a working Vulkan driver required for actual device execution.
The TLS integration test needs OpenSSL's executable and matching shared
library; on this Windows host it uses Git's `mingw64/bin/openssl.exe` and
`libssl-3-x64.dll`. Override `FOO_OPENSSL` and `FOO_TLS_LIBRARY` when needed.
Linux x64 is also exercised under Ubuntu 22.04/WSL with Nim 2.2.12 and
Clang/LLVM/LLD 14.0.0. LLVM 14 uses the matching standalone `opt` verifier,
opaque-pointer mode and `readnone` rather than the newer `memory(none)` syntax.
The selected verifier version is recorded in compiler identity. Hosted Linux
uses GNU libc and the existing pthread/resolver/dynamic-loader providers.
There is no OpenCL source compiler dependency. Cross-compilation, macOS,
other architectures and Linux runtime-none startup remain unqualified and
fail explicitly. Linux foreign calls/exports currently accept C/system only.
Windows x64 runtime-free PE linking, direct setup-free startup assembly and
interrupt object emission are verified by `test/backend/llvm/machine.nim`.
Interrupt handlers are verified as objects and are not invoked from user mode.
Baseline SSE2 feature clauses are checked; advanced CPU profiles are rejected
until separately qualified. Runtime-none allocation, text joining and issue-trail
operations remain unsupported and fail at their source operation.

## Reproduce

From the worktree root:

```powershell
node tools/native.mjs --mm refc
nim c -r --cc:clang --path:. --nimcache:.artifacts/ffi-nimcache --out:.artifacts/ffi-test.exe test/backend/llvm/ffi.nim
nim c -r --cc:clang --path:. --nimcache:.artifacts/gpu-nimcache --out:.artifacts/gpu-test.exe test/backend/llvm/gpu.nim
nim c -r --cc:clang --path:. --nimcache:.artifacts/effects-nimcache --out:.artifacts/effects-test.exe test/backend/llvm/effects.nim
.artifacts/native/foo.exe test test/library/services.iv --backend llvm --explain --no-batching
.artifacts/native/foo.exe test test/library/device.iv --backend llvm --explain --no-batching
node test/library/tls.mjs --backend=llvm
```

The FFI gate verifies LLVM IR and executes aggregate native calls/callbacks
at O0/O2, asserting returned values of 42 in native checks and reciprocal LLVM
gates in the emitted IR. Hosted entry values retain the updated workspace's
discard-value/zero-exit convention. Runtime-free machine tests check exit 42.
Both FOO functions and imported native functions can be passed as callbacks.
The test calls an exported stdcall FOO aggregate function from native code and
checks its actual PE export symbol.
Callback identities include layout attributes and variants and terminate on
recursive types; `test/backend/llvm/abi.nim` guards these cases.
All language control flow remains LLVM. Explicit native contracts and the
existing runtime providers are compiled using Clang's native ABI.

Each build retains `main.ll`, `verified.ll`, `typed-ir.json`, `llvm.json`,
per-stage command/diagnostic files and `io-batches.json` in its existing artifact
directory. Test outputs are under `test/library/.artifacts/test/llvm/<mode>/`.
The actual Clang target triple/data layout, tool versions and ABI version are
recorded in diagnostics/cache identity.
The explicit `--mm refc` compiler build matches the retained core acceptance
runner. Nim 2.2.12's default ORC configuration reproduced memory-collector
crashes during repeated frontend compilations; this option does not change
generated-program ABI or the default build mode. Its setting participates in
the native compiler build stamp.

## Current evidence

The following existing suites have passed with LLVM on this Windows host:
`services` (files, directories, streams, DNS, network interfaces, sockets,
processes, clocks, threads, task callbacks and native failure injection),
`clocks`, `virtual`, `mapping`, `ring`, `crypto`, `compression`, `cancellation`,
`simd`, `resource`, `timer`, `atomic`, `process`, `quotas`, `topology`, `ordering`,
`platform`, `dylib`, `instruments`, `issue`, `deadlines`, `socket`, `stream`,
`positioned`, `pipes`, `ipc`, `auth`, `secrets`, `blake`, `regions` and `hints`.
`bloom`, `spans` and `memory` also passed. TLS ran against an actual local
server with a trusted certificate and with certificate rejection enabled.
The dynamic-library test used an actual compiled DLL
and configured `FOO_DYLIB_TEST_PATH` so its lifetime checks were executed.
This is suite execution evidence;
it does not certify every service operation or every required acceptance case.
The vector implementation preserves ordered scalar operations and checked
integer failures. No SIMD performance specialization is claimed.

An unconditional availability assertion passed on this host. `device`, `hints`
and the focused LLVM GPU gate exercised actual Vulkan transfers/dispatch,
shared-memory barriers, atomics, invalid dispatch and resource ownership.
The focused gate checks embedded direct SPIR-V and LLVM verification and
re-executes artifacts at O0/O2. Subgroup execution follows the adapter's
capability check; unsupported devices take the explicit failure path.
This is not certification of other GPU adapters or operating systems.
Linux/WSL clocks, the broad native-service fixture, virtual memory, mappings,
processes, cancellation, atomics, SHA-256 and compression have executed successfully through verified LLVM IR and LLD. Linux aggregate
FFI/callback/export tests pass at O0/O2. Windows calling-convention/export
inspection uses PE exports; Linux inspects ELF symbols with `nm`.

I/O currently remains synchronous. The effect report identifies consecutive
same-register stream writes, retains their source/result slots, and rejects
every candidate while differential/partial-write and paired benchmark gates
are pending. Existing writes call `fflush` individually; combining them would
change per-operation visibility and error reporting. The focused effects test
checks source/result slots, different handles and intervening barriers.
Every intervening instruction and basic-block boundary is a
barrier. `--no-batching` or `FOO_IO_BATCHING=off` selects the baseline;
attempting to enable an unqualified path is an actionable error. There are no
formed batches, measured thresholds or speedup claims yet.

## Outstanding Batch 4 gates

Additional Linux/macOS and hardware-target verification;
additional GPU portability/capability tests; complete success/failure,
ownership/cleanup/ordering/platform coverage for every audited service family;
paired batching benchmarks and differential crash/failure tests; and the
complete C/Zig regression suite. Batch 4 is not complete until those gates pass.
Selected `services`, `simd`, `issue`, `device` and `compression` regressions
passed with both C and Zig. The complete native suite is a separate gate.

The io_uring capability probe has Windows and Linux/WSL tests. Linux failure
injection covers EPERM/EACCES, ENOSYS and resource-limit failures, preserves
`errno`, and closes successful probe descriptors. Capability availability does
not enable an asynchronous path or batching. The current provider stays
synchronous on every platform. Run `clang -std=c11 test/backend/llvm/ioprobe.c`
and execute its output on the host to reproduce the probe gate.

## Main workspace integration

Batch 4 commits are integrated into `main`; development and verification now
run from the main workspace. The updated target/linker pipeline is retained,
including pinned LLVM tool identities, SDK fingerprints, inspected objects,
static/shared products and offline verified native dependencies. Runtime
callbacks and exports use the v1 pointer gates rather than a second guessed
aggregate ABI. Windows x64 runtime-free PE startup/naked/interrupt contracts
remain covered by `test/backend/llvm/machine.nim`.

Build the current workspace compiler with
`node tools/native.mjs --mm refc --output .artifacts/batch4-main/foo.exe`.
Set `FOO_COMPILER` to that absolute executable path and run
`node tools/llvm-runtime-acceptance.mjs` for the C/Zig/LLVM library matrix,
real dynamic-library fixture, TLS and native tests. On a host with a Vulkan
adapter, set `FOO_REQUIRE_GPU=1` to require actual adapter execution.
Evidence is saved under `.artifacts/llvm-runtime-acceptance`; `passed` stays
false until all checks succeed. This command does not qualify I/O batching.
The current main toolchain policy pins LLVM 18.1.3; the earlier isolated Linux
LLVM 14 results are historical evidence and do not override that policy.
