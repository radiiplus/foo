# QBE Backend Support

FOO's active build backend accepts `--backend qbe`. Runtime-free x64, ARM64,
and RISC-V ELF builds, UEFI x64 applications, and hosted Windows x64/Linux x64/Linux ARM64 builds accept
`--mode release`. Hosted release correctness is qualified by the listed target
gates; performance claims apply only to their recorded source snapshots. Shader
products and the WebAssembly route have separate lowering and build
identities. QBE 1.3 emits native assembly. Bundled target assemblers produce
Linux ELF objects; TinyCC compiles `src/runtime/qbe.c` and links hosted programs.
Windows uses bundled TinyCC for hosted builds. The Linux x64 package bundles
QBE, TinyCC, musl, and x64/ARM64/RISC-V ELF assemblers and linkers. Hosted
Linux x64 and ARM64 builds from that package use target-specific TinyCC and
musl without a host C toolchain.
The Linux ARM64 host package bundles native AArch64 QBE, static TinyCC and a
static GNU assembler, plus ARM64 musl headers and libraries. Hosted builds on
an ARM64 host use these bundled tools without a separate C compiler or
assembler. The package's ARM64 toolchain gate runs the binaries under QEMU;
the complete compiler process has not been run on ARM64 hardware in this gate.
The raw Linux syscall entry points live in separate architecture assembly files
under `src/runtime/`.
Freestanding ELF linking uses the bundled target-specific GNU ld on Linux x64,
with an optional project linker script and no hosted runtime objects.
Executables require either a module-level `native asm` contract defining
`_start` or a function marked `start`; the latter defines `_start` as an alias.
The linker checks `_start` and unresolved
symbols, removes unused sections, and uses 4 KB segment alignment.

## Targets

| FOO target | QBE target | Current build coverage |
| --- | --- | --- |
| `windows-x64` | `amd64_win` | Thirty-nine hosted feature/semantic cases pass in dev and release; public C and native QBE functions can be built as a shared DLL with explicit exports. |
| `linux-x64` | `amd64_sysv` | Thirty-nine static hosted feature/semantic cases pass in dev and release. |
| `linux-arm64` | `arm64` | Thirty-nine static hosted feature/semantic cases pass in dev and release under QEMU user mode. |
| `x64-freestanding` | `amd64_sysv` | Dev/release checked integer ELF exits 42 under WSL; no-error-code interrupt wrapper returns from software and PIT IRQs under QEMU. |
| `arm64-freestanding` | `arm64` | Dev/release checked integer and EL1 exception/SGI interrupt gates pass under QEMU. |
| `riscv64-freestanding` | `rv64` | Dev/release checked integer, machine interrupt, and 8/16/32/64-bit atomic gates pass under QEMU. |
| `uefi-x64` | `amd64_win` | Dev/release PE32+ EFI applications boot in OVMF through a public C ABI `efi_main`; vendored TinyCC produces the image and relocation directory. |
| `wasi` | WAT via WABT | Dev/release scalar and local aggregate functions, memory, scalar WASI imports, and direct WABT executable modules; broad services unqualified. |
| `wasm-freestanding` | WAT via WABT | Scalar object and no-entry executable with memory, local arrays and records, and external imports. |
| `wasi-threads` | WAT via WABT | Dev/release shared-memory atomic objects pass a four-thread C consumer under WAMR; standalone executables pass a four-worker Node gate. |
| `spirv-vulkan1.3` | direct SPIR-V | Dev/release shader product with bundled `spirv-val` validation. |

QBE 1.3 also has `amd64_apple` and `arm64_apple` native targets. They are not
enabled in this FOO build route. A packaged install finds QBE beside the
frontend; `FOO_QBE` overrides it. `FOO_QBE_TCC` selects a development TinyCC
binary on Windows; packaged builds find it beside the frontend. The release
asset requirements are in `toolchain/assets.json`. The Linux x64 package uses
its target-specific bundled assemblers and linkers for freestanding ELF objects
and executables. Windows native hosted builds use the Windows TinyCC assembler.
Windows freestanding cross-builds invoke the bundled Linux x64 ELF tools through
WSL; WSL is required on that host for these targets.

For the deployable Linux layout, `tools/qbe/minimal/stage.mjs --package
<staged-source-package> --output <new-directory>` verifies the installation
receipt and stages the runtime toolchain and standard library under the 55 MB
uncompressed limit.

Hosted executable builds accept C sources, include directories, compiler flags,
prebuilt objects, and native libraries through the project build configuration.
Library file paths in a project manifest resolve from the project root.
Freestanding executables accept prebuilt target objects and libraries; C sources
must be compiled for the target separately. Static archives can contain C
sources and prebuilt objects. Source, object, path-based library, and include
file hashes are recorded in QBE build metadata and the cache key. Builds with
libraries named through `-l` are relinked on every invocation because the
resolved system library is not part of the hermetic input set. Hosted release
mode keeps the generated C runtime at `-O0`; it has no qualified target-specific
runtime optimization policy. `tools/qbe/hosted/verify.mjs` checks the
five feature programs plus JSON, cleanup, allocation, storage, bounds, file
success and error paths, checked integer overflow, arena-backed memory,
sequence ownership, and typed JSON optional/error cases in both modes. It also
compares compiler source hashes. `--probe-all`
records additional open fixtures without qualifying them.

Hosted Windows x64 and Linux x64 release executables lower two-field
`unsigned`/`boolean` JSON records through a direct scalar call with a static
field plan. Other record shapes, dev builds, shared libraries, and other
targets retain descriptor lowering. Noncanonical input on the direct path
falls back to the shared JSON decoder. The selected `codecLoweringPolicy` is
recorded in build metadata and cache identity. For a matched control build,
`FOO_QBE_TYPED_CODEC=descriptor` selects the descriptor path in release mode.
Recheck this lowering path with `tools/qbe/hosted/verify.mjs` before relying on
it for a new compiler revision.

The hosted QBE runtime supports checked allocator creation, allocation,
expansion, release, close, views, byte copies, transfer, clear and comparison.
Arena-backed `allocate` returns an owned byte sequence. Pointer-free typed
sequences can be copied and compared lexicographically; byte equality keeps
the existing text comparison path. The file gate covers `fs.exists`,
`fs.read`, `fs.write`, `fs.open`, `fs.remove`, standard stream I/O, and
`resource.files`. Read buffers use the releasable text ownership path;
opened handles are tracked and closed at process exit. The hosted thread gate
covers spawn/join, mutex, condition signal, and close with explicit fallible
result storage. The hosted atomic service gate covers 64-bit load, store,
fetch arithmetic, exchange, compare-exchange, and invalid memory-order errors.
Typed JSON gates include wide integers, packed records, tagged choices,
optionals, and fallible values on Windows x64, Linux x64, and Linux ARM64.
Higher-level task pools, cancellation, foreign atomic interoperability on
ARM64, and arbitrary shared-state races remain unqualified. Network, process,
and high-level WASI service contracts remain outside this gate.
Run `tools/qbe/hosted/verify.mjs` against the current source before claiming
hosted correctness for a new revision.

Windows x64 shared products use vendored TinyCC and export only public QBE
functions. `tools/qbe/shared/verify.mjs` checks dev and release DLLs through
a separately compiled C consumer. The shared path currently accepts the
normal C and native QBE ABIs; custom export lists and version metadata are
still unsupported. Windows package staging runs this consumer gate against
the staged TinyCC executable and DLL pair. Linux shared linking remains disabled: the current bundled
TinyCC path leaves text relocations in a shared ELF. Debug information,
coverage, profile, and sanitizer products remain unsupported.

Freestanding ELF now lowers volatile scalar and aggregate access to target-native
assembly. The 8-, 16-, 32- and 64-bit atomic load, store, add, subtract, swap
and fence helpers run on x64, ARM64 and RV64. Source declarations can request
placement with `dynamic cpu_page of type unsigned aligned to 4096 in section
".percpu" is 0.` The section remains writable and allocated, and the ELF
symbol receives the requested alignment. Public freestanding globals remain
available to linked native startup objects. This is a per-CPU template mechanism;
secondary-core startup and copying each CPU's template remain platform code.
Freestanding thread-local storage and heap or region allocation require a
target-provided setup and fail with explicit diagnostics.

`uefi-x64` emits `BOOTX64.efi`-style PE32+ images with the Microsoft x64 C ABI
on the qualified Windows TinyCC host.
The entry must be a public `efi_main` taking image-handle and system-table
pointers and returning unsigned 64-bit EFI status. The UEFI build has no hosted
runtime or import libraries; TinyCC may compile target C sources and link COFF
objects. The current UEFI route rejects QBE wide-integer, atomic and volatile
helpers until PE-native support is provided. `test/backend/qbe/scripts/uefi-boot.mjs`
checks PE headers, relocations and a live OVMF boot in dev and release.

Foreign `system` ABI adapters support standard-layout records, arrays, unions,
and 65- to 128-bit integer storage as aggregate values. The generated C bridge
checks aggregate size and record field offsets at compile time. Windows
`vectorcall` still accepts scalar signatures only: the bundled TinyCC compiler
rejects aggregate results, so the QBE driver reports that limit before C
compilation. Other managed, packed, and tagged aggregate signatures remain
outside the bridge's qualified subset.

On hosted x64 targets, the bundled TinyCC runtime uses hardware atomics for
8-, 16-, 32-, and 64-bit values. A four-thread probe checks those operations
against atomics in a separately compiled TinyCC C object. ARM64 retains its
existing runtime path; foreign atomic interoperability there is unqualified.

`test/backend/qbe/riscv/board.mjs` boots a RISC-V release ELF in QEMU and
checks the UART result. A separate TinyCC gate can assemble QBE's RISC-V output
into a raw firmware image; that path is not yet selected by the driver.

WebAssembly builds require WABT `wat2wasm` on `PATH` or the
`FOO_WAT2WASM` override. The driver emits complete executable modules directly
and uses `--relocatable` only for object products; WASI entry functions import
`wasi_snapshot_preview1.proc_exit` to return an integer status. The WAT
lowering accepts 8/16/32/64-bit scalar storage, 32-bit pointers, stack slots,
scalar loads/stores, arrays and records with nested copies, checked indexing,
scalar static data, and direct calls. Internal and external aggregate calls
use copied memory values and a leading result pointer. Direct Preview1 imports
cover file descriptor I/O, path opening, seeking, clocks, randomness, and
thread spawning. The
execution gate checks arithmetic overflow and bounds traps, public storage,
file I/O, clocks, randomness, and aggregate by-value behavior.
The `wasi-threads` executable imports shared memory, exports `_start` and
`wasi_thread_start`, and reserves separate stack ranges for worker instances.
Its dev and release gates spawn four workers and check a shared atomic counter.
The object path still supports the WASI SDK pthread consumer under WAMR.
Both paths lower 32/64-bit atomic load/store/add/sub/swap and fences;
unthreaded targets reject atomics. High-level text/file APIs, dynamic
allocation, escaping stack pointers, thread-local data, and nonzero shared
static initializers remain unqualified. WABT remains an external tool.
Shader products use the existing GPU/SPIR-V emitter
and the bundled validator without invoking QBE or WABT. Tool hashes, mode,
target and lowering policy are recorded in artifact metadata and cache keys.

## Native QBE IL

- Base values: 32- and 64-bit integers (`w`, `l`) and 32- and 64-bit floats
  (`s`, `d`). Bytes and halfwords (`b`, `h`) are storage and ABI types;
  pointers use a machine integer representation.
- Data and layout: named structs, unions and opaque aggregates, alignment,
  static data, thread-local data, exports, sections, and external/PIC symbols.
- Control: functions and blocks, conditional and unconditional jumps,
  returns, termination, and phi values.
- Operations: integer and floating arithmetic, bitwise shifts and logic,
  comparisons, conversions, casts and copies, stack allocation, loads,
  stores, and fixed-size memory copies.
- Calls: C ABI parameters and returns, including subword and aggregate
  types, indirect calls, varargs, and an environment parameter for closures.

QBE has no WebAssembly target or native IL instructions for atomics and SIMD
vectors. Its IL does not implement ownership, bounds checks, checked overflow,
or system services by itself; the FOO emitter and runtime must implement
those contracts. The FOO emitter currently supports only a subset of QBE's C
ABI and language features and rejects unsupported instructions and build
configurations. Run the relevant target gates in
[`test/backend/qbe/TARGETS.md`](../test/backend/qbe/TARGETS.md) to qualify a
new source revision.

FOO lowers checked scalar arithmetic and comparisons for 1-128-bit integers,
packed-record comparisons, and nonstandard-width bit operations through its
QBE runtime. Freestanding x64, ARM64, and RV64 products link source-hashed
TinyCC integer objects from `vendor/tcc/freestanding`; checked failures trap
without a hosted panic service. Rebuild the objects after changing `qbe.c`.
Windows x64 release builds inline checked arithmetic and comparisons for
integer widths 1-31 and 33-63 using QBE's native 32- and 64-bit operations.
The 32- and 64-bit paths are unchanged, and widths 65-128 retain the runtime
helpers. Dev and other targets retain the generic narrow-width policy.
`FOO_QBE_NARROW_INLINE=0` selects the generic path on Windows release for a
matched control build. The selected `narrowIntegerPolicy` is in build metadata
and cache identity. This improves scalar operations; standalone 2- and 4-bit
values still occupy a byte, and arrays are not implicitly bit-packed. The
Windows policy passed its recorded release gate; later source changes need
fresh target gates and measurements before making new speed claims.
Setup-free function assembly uses named `@asm` contracts; `start` and
`target_feature` are validated per function. Interrupt wrappers cover x64
vectors with or without a hardware error code, ARM64 EL1/EL2/EL3, and RV64
machine mode. The x64 error-code form passes one unsigned 64-bit argument and
removes the CPU-pushed word before `iretq`; EL2/EL3 use their level's
`ELR`/`SPSR` for `eret`. RV64
freestanding atomics cover aligned 8/16/32/64-bit values. Deferred and catch
bodies accept local multi-block graphs with branches, loops, block parameters,
phi values and multiple exits, including `try` in a deferred body. Source
lowering and direct QBE IR expand nested deferred blocks in reverse
registration order. Release qualification covers x64 page faults and ARM64
EL2/EL3 same-level synchronous exceptions in QEMU. Other exception classes
and physical-board delivery need separate target gates.
The target gates are listed in
[`test/backend/qbe/TARGETS.md`](../test/backend/qbe/TARGETS.md).

QBE references: [IL specification](https://c9x.me/compile/doc/il.html),
[1.3 release notes](https://c9x.me/compile/release/qbe-1.3.html).
