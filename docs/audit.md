# Optimization audit

FOO 0.7.1, source inspection on 2026-10-09. This is a working audit, not a
claim that the master performance checklist is complete. The baseline
environment and raw results are recorded alongside each optimization below.

## Architecture and measurement boundary

`src/build/compiler.nim` lowers, specializes, validates, runs release
optimization, and validates again before emitting C or Zig. `src/backend/c`
and `src/backend/zig` implement the hosted runtime. `lib/*.iv` supplies FOO
library code and native service declarations. `benchmark/results.json` and
`docs/performance.md` cover process-level workloads, while
`benchmark/algorithms.md` covers packed counting and sorting. Process startup
is material for short operations, so operation-level timers are required for
algorithm changes. C and Zig builds must be checked separately.

## Prioritized findings

| Priority | Component and call path | Evidence and bottleneck | Proposed change and expected effect | Risks and validation |
| --- | --- | --- | --- | --- |
| 1, implemented | `lib/bitmap.iv`: `merge/intersect/difference/symmetric -> blend -> arch.combine` | The old path unpacked each 64-bit word in a 64-step loop. The paired operation median was 117.44 ms on the fixed fixture. | Native packed-word OR/AND/AND-NOT/XOR reduces the median to 1.41 ms (83.2x) on this fixture. Results still allocate independent owned output. | C and Zig bitmap tests, C freestanding cross test, exact checksum, native unaligned/invalid-input test, generated x86-64 inspection. No SIMD dispatch was needed. |
| 2, implemented | `src/backend/zig/library.zig`: `arch.tally -> bitmap.count` | The generic x86-64 build emitted no `popcnt` instruction; the paired prior Zig median was 2.4505 ms. | CPUID-guarded `popcntq` on the Zig LLVM x86-64 path reduces the paired median to 1.8383 ms (25.0%) on the same fixture. Dev Zig and other architectures retain `@popCount`. | Zig dev and release checksum, 31 paired samples, emitted instruction check, AArch64 dev/release cross-build; untested runtime on hardware without POPCNT. |
| 2 | `lib/sequence.iv`: stable sort and merge | Stable merge sort uses temporary storage and repeated passes; exact copy and allocation cost has not been measured. | Profile sizes and ownership paths before changing buffer reuse. | Stability, branch ownership, empty and duplicate inputs; compare equivalent C/Zig controls. |
| 3 | `lib/bitmap.iv`: `rank/select/get/put` | `mask` and partial-word scans are linear in bit position; `put` copies the entire bitmap. | Measure rank/select distributions; consider native word primitives if these operations dominate. | Bounds, 64-bit extremes, persistent ownership; random differential tests. |
| 4 | `src/backend/c/runtime.h` and `src/backend/zig/library.zig`: sequence allocation and copying | Existing process benchmarks show workload-dependent backend differences, but do not isolate allocation count or bytes copied. | Instrument a representative generated program before changing representation or ownership lowering. | Borrow invalidation, cleanup, retained branches; both backends and debug/release. |
| 5 | `src/backend/c/driver.nim` and Zig driver: optional native services | Build gates select crypto/compress/HTTP/Vulkan sources by use, but startup and binary-size impact needs a paired minimal-program measurement. | Compare minimal versus one-service programs and inspect linked dependencies. | Accidental eager linkage; size, startup, dynamic imports on each host. |

## Scope still requiring evidence

Task scheduling, networking, file and VM operations, processes, cryptography,
compression, GPU transfer and dispatch, CPU-specific byte processing, target
portability, and the remaining library modules need dedicated workloads before
an optimization can be justified. Existing conformance tests establish behavior
but are not performance profiles. No performance claim is made for these areas.

## Dependency boundary

`vendor/libsodium` and `vendor/zlib` contain Windows x64 static libraries;
`vendor/vulkan/volk.c` is source-linked only for selected Vulkan programs.
The MoltenVK tree is an upstream source snapshot and is not compiled by the
Windows build. OS libraries and drivers are outside FOO's source control.
Dependency provenance, update steps, and patch records belong in
`docs/vendor.md`.

## Packed bitmap result

The fixture is `benchmark/algebra.iv`: 30,000 64-bit words per input, two
rounds of union, intersection, and difference, and a checked result checksum
of 4,162,660. It initializes inputs before the monotonic operation timer.
`benchmark/control.cpp` performs the same six owned output allocations,
bitwise passes, and population counts. `benchmark/compare.mjs` warms each
binary twice and alternates paired samples (nine by default, 31 for the Zig
comparison); it records every operation
and whole-process observation. All results are from Windows x64 on an Intel
Core i5-1145G7, using FOO 0.7.1 release mode, Zig 0.16.0, and Clang 18.1.3.

| Comparison | FOO operation median | Control median | Interpretation |
| --- | ---: | ---: | --- |
| C backend after vs C backend before | 1.4111 ms | 117.4396 ms | 83.2x on this fixture; raw data in `benchmark/baseline.json`. |
| C backend after vs C++20 | 3.3861 ms | 2.9550 ms | FOO was slower in this validation run; raw data in `benchmark/control.json`. |
| Zig backend after vs prior Zig | 1.8383 ms | 2.4505 ms | 26/31 paired wins, two-sided sign-test p=0.00019; raw data in `benchmark/algebra-zig-change.json`. |
| Zig backend after vs C++20 | 1.1084 ms | 0.7072 ms | C++ was faster in this separate run; raw data in `benchmark/zig.json`. |

The old C executable is 168,960 bytes and the optimized one 167,936 bytes.
The prior Zig executable is 619,008 bytes and the guarded-POPCNT one 619,520
bytes, a 512-byte increase.
An earlier C++ comparison measured 1.7744 ms for FOO and 1.6560 ms for the
control; the table now uses the fresh paired samples from the renamed runner.
The optimized executable imports only `KERNEL32.dll`; this fixture does not
link libsodium, zlib, or Vulkan. An instrumented C release run reports nine
allocations, 1,920,008 allocated bytes, zero copied bytes, and 1,200,000 peak
tracked bytes. The old executable was not instrumented, so no measured
before/after allocation claim is made. Whole-process timing contains large
startup and scheduler variation and is not used for the speedup claim.

The generated C release binary contains scalar `orq` and `andq` packed-word
instructions in the hot path. The implementation also has a portable scalar
path and no runtime feature requirement. The fixed-width copy uses a compiler
builtin on Clang/GCC so freestanding targets need no libc declaration; the
Windows MSVC path uses `memcpy`.
The Zig path detects POPCNT with CPUID only in LLVM x86-64 builds, then uses
`popcntq` for each packed word. Zig 0.16's non-LLVM x86 backend cannot encode
that instruction in inline assembly, so dev builds use the portable loop.
AArch64 dev and release cross-builds succeeded, but no AArch64 runtime result
is claimed from this Windows host. Short bitmap counts and x86-64 machines
without POPCNT still need dedicated performance samples.

Reproduce after building the native compiler:

```powershell
node bin/foo.mjs build benchmark/algebra.iv --backend c --mode release --target windows-x64
Copy-Item .artifacts/build/app.exe .artifacts/algebra-after.exe
clang++ -O3 -std=c++20 -march=native -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH benchmark/control.cpp -o .artifacts/control.exe
node benchmark/compare.mjs .artifacts/algebra-after.exe .artifacts/control.exe a benchmark/control.json native
node bin/foo.mjs test test/library/bitmap.iv --backend c --target windows-x64
node bin/foo.mjs test test/library/bitmap.iv --backend zig --target windows-x64
node bin/foo.mjs build benchmark/algebra.iv --backend zig --mode release --target windows-x64
node benchmark/compare.mjs .artifacts/algebra-zig-after.exe .artifacts/algebra-zig.exe a benchmark/algebra-zig-change.json foo .artifacts/algebra.bin .artifacts/bitmap-algebra-time.bin 31
node bin/foo.mjs build benchmark/algebra.iv --backend zig --mode release --target linux-arm64
```

The before binary is preserved locally at `.artifacts/algebra-before.exe`;
`benchmark/baseline.json` contains the paired before/after samples.
The focused C/Zig bitmap and bit-operation suites pass. The 70-module
standard-library check passes. The native suite initially reported six failures:
one freestanding C compilation failure fixed by the builtin copy path, three
stale platform/dependency expectations fixed and rerun individually, and two
parallel WASI timeouts that passed individually. A serial native run then
found an obsolete GPU test that parsed SPIR-V as OpenCL text; the test now
checks the binary payload and passes directly. The full `test lib` C run exited
without diagnostics after a long compile, so it cannot be counted as passed.
The final native rerun passed 35/35 suites with two workers, including the
SPIR-V and WASI cases.
