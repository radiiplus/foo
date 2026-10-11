# C/Zig to LLVM migration audit

Batch 0, audited 2026-10-10. This is a migration proposal, not an implemented backend or a certification that every declared target works. Paths are relative to the repository root. **Implemented** below means source evidence exists; **tested** means a test exists, not that it was executed in this audit. **Unverified** means evidence is incomplete or execution has not been established.

## Scope and evidence limits

The current package is FOO 0.8.1 (`package.json`). The live compiler is Nim (`src/main.nim`, `tools/native.mjs`), launched by Node (`bin/foo.mjs`), not the TypeScript compiler still described in `specs/toolchain.md`. Historical `release/foo-v*/` trees are packaging evidence, not authoritative current implementation. No AGENTS.md was found in the working tree search.

The checkout already contained edits to `CHANGELOG.md`, `docs/projects.md`, `src/backend/c/driver.nim`, `src/build/execute.nim`, `src/cli/main.nim`, `src/test/runner.nim`, `test/runner.nim`, and untracked `src/test/cache.nim`, `test/build/execute.nim`, `output/`, and registry indexes. Final status inspection also showed a newly appearing untracked `src/backend/llvm/` directory, not created or audited by this batch. This audit reads the C/Zig working-tree baseline; these external changes must be included in any subsequent baseline or separately reviewed. Batch 0 changes only this document.

Read-only checks: file enumeration with `rg --files`; symbol/content searches with `rg -n`; PowerShell file reads and directory enumeration; `git status --short`; command discovery; `clang --version` and `node --version`. Observed host tools: Clang 18.1.3 targeting x86_64-pc-windows-msvc, Node v24.11.1. `nim`, `zig`, and QEMU were not discovered on PATH by the selected command lookup. `.artifacts/toolchain/0.16.0/` contains `zig`, `lib`, `doc`, LICENSE and README; presence does not certify host compatibility, receipt validity or executable version. Choosenim/private installations may exist outside PATH and were not certified.

No build, test runner, package installation, doctor, toolchain installer, benchmark or target execution was run. Those can create artifacts, download dependencies or execute hooks. Consequently all runtime/platform results remain unverified here; the acceptance gate for this batch is documentary coverage, not test success.

## Compiler and build map

| Area | Concrete current paths and responsibility | Migration boundary |
| --- | --- | --- |
| Entry and commands | `bin/foo.mjs` locates/version-checks native compiler, sets Zig cache environment; `src/main.nim` calls `src/cli/main.nim`; `src/cli/runner.nim`, `project.nim`, `link.nim`, `display.nim` | Add LLVM selection without bypassing version checks, command diagnostics or project behavior. Current CLI accepts only c/zig; default project/test/benchmark selection is Zig. |
| Front end | `src/lex/`, `parse/`, `ast/`, `sema/`, `types/`; `src/build/compiler.nim` orchestrates checking and IR | Keep language rules shared. Backend selection already affects compilation context; audit those dependencies before calling it backend independent. |
| IR | `src/ir/node.nim`, `kind.nim`, `lower.nim`, `eval.nim`, `monomorph.nim`, `reach.nim`, `valid.nim`, `parse.nim`, `print.nim` | Preserve typed blocks, effects, native contracts, evaluation, specialization and reachable operations. Validate immediately before LLVM lowering. |
| Backend dispatch | `src/build/execute.nim`, `options.nim`; `src/backend/substrate.nim`; `src/opt/engine.nim`, `arch.nim`, `vector.nim`, `gpu.nim`, `spirv.nim`, `profile.nim` | Introduce an explicit LLVM target/ABI adapter and shared result contract. Substrate currently marks modules `@c`, binds native contracts to C/asm, and contains c/zig candidate restrictions. |
| Generated source | `src/backend/c/emitter.nim`, `runtime.nim`; `src/backend/zig/emitter.nim`, `shim.nim`, `driver.nim`; `src/backend/asm/emitter.nim`; `src/backend/docs.nim` | Emit LLVM IR/object files directly for FOO functions. Generated runtime wrappers and docs need replacements or retained interfaces. |
| Native fragments | `src/backend/native/escape.nim`, `machine.nim`, `service.nim`, `service.h`, `service.c`, `gpu.c`, `vulkan.c`, `icon.nim` | Keep declared C and assembly escape contracts and selective service compilation. C fragments are runtime/FFI dependencies even after FOO C emission disappears. |
| Runtime | `src/backend/c/runtime.h`, `arch.h`, `json.h`, `http.h`, `storage.h`, `stream.h`, `memory.c`, `trace.c`, `copy.c`; Zig `library.zig`, `storage.zig`, `stream.zig`, `service.zig`, `shim.zig`; `lib/*.iv` | Extract a stable target-aware runtime ABI; replace Zig-only providers before removing Zig. Retain C compilation via managed Clang where appropriate. |
| Project/link pipeline | `src/build/config.nim`, `project.nim`, `files.nim`, `tasks.nim`, `execute.nim`, `release.nim`; `src/cli/link.nim` | Preserve exe/static/shared products, dependency ordering, C/C++ sources, objects, library/include flags, frameworks, linker scripts, exports, rpaths, SONAME/version, icons, hooks, deployment and signing. |
| Managed tools | `src/toolchain/manager.nim`, `native.nim`, `doctor.nim`; `tools/toolchain.mjs`, `toolchain.json` | Replace Zig distribution assumptions with checksummed LLVM and explicit target support packages/receipts. Doctor is not purely informational: native dependency preparation can provision packages. |
| Distribution | `tools/native.mjs`, `build.mjs`, `source.mjs`, `binaries.mjs`, `sign.mjs`, `build.ps1`; `installers/linux/package.sh`, `installers/windows/foo.iss`, `foo.rc` | Compiler bootstrap is a separate Nim-to-C build. It still needs Nim and a C compiler even after FOO gains LLVM output. Windows bootstrap uses llvm-rc; Linux x64-to-arm64 bootstrap currently wraps managed Zig cc. |
| Tests/benchmarks | `src/test/runner.nim`, `cache.nim`; `src/benchmark/runner.nim`; `test/native/run.mjs`; `tools/benchmark.mjs`, `benchmark/compare.mjs` | Preserve discovery, filtering, dev/release modes, compilation/execution accounting, watch/cache and reporting. |

`tools/native.mjs` embeds native C/Zig/runtime fragments with staticRead and hashes their inputs into `embedded.sha256`. `tools/build.mjs` stages vendor/lib/docs and the native executable, strips npm dependencies, retains a toolchain postinstall, and hardcodes backend 0.16.0 in `foo.artifact.json`. Updating only the language emitter would leave old runtime bytes and toolchain contracts in distributions.

### C/Zig-specific behavior inventory

* C driver (`src/backend/c/driver.nim`) selects explicit compiler, host Clang/cc or detected managed tool; recognizes Zig and invokes `zig cc`. Freestanding/WASI project builds automatically supply managed Zig when no explicit C compiler exists (`src/build/project.nim`). Generated translation units are C11, not LLVM IR.
* C flags include POSIX/Darwin feature macros, O0/debug versus O2/g0, function/data sections, platform dead stripping, release stripping, PIC/shared, sanitizer selection, CPU profile flags and platform libraries. Runtime none adds freestanding/no-stack-protector and nostdlib with `_start`; threads add atomics/bulk-memory/pthread and shared-memory linker flags. Link flags and archives must be translated per object format, not copied blindly to all LLD flavors.
* C representation rounds integer widths to 8/16/32/64/128 storage; >64-bit storage currently requires compiler `__int128` support and emits an error otherwise. Packed C records currently permit backing widths 1–64, not arbitrary 128-bit packed records. C arrays/vectors are lane structs; aggregates use generated typedefs. C equality/ordering explicitly reject some aggregate layouts.
* Checked C arithmetic uses generated range guards and selected compiler overflow builtins; zero division and signed minimum/-1 trap. LLVM must preserve these checks in release, including non-storage widths, conversions and shifts, rather than introducing poison through unchecked `nsw`/`nuw` assumptions.
* C startup/panic, coverage and benchmark code, arena cleanup and error trace machinery are emitter/runtime responsibilities. C interrupt/naked/compiler feature attributes and inline assembly depend on compiler/architecture support. See `src/backend/c/emitter.nim`, `src/backend/native/machine.nim`, `src/backend/asm/emitter.nim`.
* Zig uses native integer widths, optional types (`?u32` is asserted by `test/backend/zig/emitter.nim`), packed/type declarations, Zig calling conventions and generated control flow. It writes `main.zig`, `shim.zig`, `library.zig`, `storage.zig`, `stream.zig`, and sometimes `service.zig` and a C escape fragment. These are not interchangeable layouts by assumption.
* Zig driver (`src/backend/zig/driver.nim`) invokes build-exe/build-lib, Debug/ReleaseSafe, local/global caches and bounded jobs; uses `-fno-llvm` for eligible dev builds, LLVM/LLD when needed, release stripping, dynamic libraries, target/CPU flags, libc discovery/config and MSVC UCRT/vcruntime handling. Freestanding uses `-fno-entry`; shared WASI enables atomics/bulk memory. It also compiles shared C native/Vulkan services. Zig docs/sanitizer switches have no direct LLVM-driver equivalent.
* Copy specialization in `src/backend/substrate.nim` distinguishes Zig word/block-16/block-32 from C portable/intrinsic/rep/AVX paths, while atomics select C11. SIMD and task candidate lists explicitly name old backends. Native contracts resolve C/asm even under Zig; deleting all C support would break the language's native and foreign interfaces.

## Target preservation matrix

Source of truth for implemented preset names is `src/targets/presets.nim` with triple/config translation in `src/build/config.nim`, `src/opt/arch.nim` and driver options. `specs/targets.md` is a contract that exceeds the current preset table in places.

| Target/mode | Evidence and present limits | LLVM requirements beyond host IR |
| --- | --- | --- |
| Linux x64, x64-v3, arm64 GNU; Linux musl x64 | Implemented presets; C cross tests `test/backend/c/cross.nim`; host execution `test/backend/c/execute.nim`, Zig driver tests; v3 dispatch evidence in substrate/arch tests. Execution not certified here. | ELF linker, glibc/musl sysroot, startup objects, compiler builtins, deployment minimum and CPU feature mapping. |
| Linux musl arm64 | Listed in `specs/targets.md` but absent from current preset table. Raw aarch64-musl used by `test/platform/language.mjs`; that script uses stale JS modules. Preset support unverified. | Separate musl arm64 sysroot and repaired test, not an inferred preset. |
| Windows x64, x64-v3, arm64 MSVC | Implemented presets; x64 bundled native libraries exist. arm64 SDK/native dependency availability unverified. | COFF, lld-link, Windows SDK/UCRT/vcruntime/import libraries, resources, ABI thunking; x64 static libraries cannot serve arm64. |
| macOS arm64 | Implemented preset; Darwin flags/frameworks and service branches. `taskBackend` falls back to threads; kqueue specialization explicitly `evidenced = false`. | Mach-O, Darwin SDK/startup/system frameworks, deployment target; codesigning/distribution separately. |
| macOS x64 | Spec row, absent from current preset table; raw triple handling is not proof of full preset support. | x64 Darwin sysroot plus actual build/run gate. |
| WASI wasm32 | Implemented preset and `test/backend/c/wasi.nim`; test builds empty module and checks wasm magic only. | wasm-ld, WASI libc/CRT/sysroot, import/export policy, compatible execution runner. Magic-byte success is not library/runtime parity. |
| Threaded WASI | Implemented preset; `test/backend/c/threads.nim` checks generation/magic only, no worker execution. | Shared-memory/atomics/bulk-memory feature policy, threaded WASI runtime/sysroot and runner, memory limits/imports and actual task/atomic execution. |
| wasm freestanding | Implemented preset, documented runtime-none contract; end-to-end execution unverified. | Explicit exports/entry/memory policy, no WASI/libc imports, target builtins if LLVM introduces helper calls. |
| AArch64/RISC-V64 freestanding | Implemented presets; `test/backend/c/cross.nim` checks ELF machine; `test/platform/gates.mjs arm riscv` builds both backends and checks `_start`, entry/load segment then QEMU serial marker; fixtures `.iv`/`.ld` in `test/platform/fixtures/`. Not run here. | ELF/LLD linker scripts, board memory map/startup/stack, builtins policy and QEMU/device execution. Successful codegen alone is insufficient. |
| Hardware, startup, interrupt, without setup, using feature | Parser/type/backend tests: `test/parse/machine.nim`, `test/backend/machine.nim`, `test/backend/asm/emitter.nim`, both emitter tests; target contract in `specs/native.md`, `specs/targets.md`. AArch64 is not the ARM/thumb interrupt case in Zig functionConvention; every interrupt target combination needs verification. | Architecture-specific calling convention and naked restrictions, volatile/MMIO semantics, register/clobber verification, vector tables and board support. Windows hardware workflow requires Linux/WSL/QEMU per toolchain contract. |
| Runtime none (both backends) | Driver/emitter implementation and spec prohibit hosted services, allocation/text joining, coverage/benchmark instrumentation. | Reject unsupported operations before codegen; prove no libc, allocator, stack protector, sanitizer or hidden compiler helper import. |
| GPU/SPIR-V/Vulkan | `src/opt/gpu.nim`, `spirv.nim` emit SPIR-V words directly; `src/backend/native/gpu.c`, `vulkan.c`, `lib/gpu.iv`, `vulkan.iv`; optimization tests in `test/build/native.nim`, `test/opt/engine.nim`, `test/optimization/`. Device execution/complete operation coverage unverified. | Preserve separate kernel compiler plus host Vulkan runtime, loader/driver, buffer/workgroup/subgroup/atomic contracts and CPU fallback. A host LLVM target does not replace this path. |

All current presets are little-endian by contract; wasm32 pointers differ from 64-bit hosted/bare-metal targets. Advanced versioned descriptors/catalog/digest requirements described in `specs/targets.md` must be reconciled with the simpler current Target object. Do not claim the full advanced schema is implemented solely from its specification.

## Language and library operation map

Each row names the current lowering/runtime and concrete tests to retain. These are coverage anchors, not claims of exhaustive validation of every combination.

| Construct/operation | Current implementation | Test evidence and migration obligation |
| --- | --- | --- |
| Records, C records/unions, packed layout, alignment, reflection | `src/types/checker.nim`, `src/ir/lower.nim` (Reflect/record kinds), `eval.nim`; C Types.getImpl and Zig emitTypeDecl; layout contract `specs/abi.md` | `test/types/layout.nim`, `test/types/checker.nim`, `test/ir/eval.nim`, `test/library/layout.iv`, `members.iv`, `derive.iv`, both emitter tests. Measure target size/alignment/offsets; do not reuse host size for cross targets. |
| Signed/unsigned widths 1–128 and checked arithmetic | C integer helper generator; Zig integer type/arithmetic emission; coercion/type checks in `src/types/coerce.nim`, `checker.nim` | `test/backend/c/emitter.nim` explicitly checks i7 and u100 storage; `test/backend/zig/emitter.nim`, `test/types/foundation.nim`, `test/types/coerce.nim`, `test/library/algebra.iv`, `bits/main.iv`, `cast.iv`, `test/completion/overflow.c`, `benchmark/arithmetic.iv`. Complete all-width boundary matrix is unverified and must be added during migration. |
| Optionals/choices/exhaustiveness | IR kinds/lowering; C bool+value optional, u32+union choice; Zig optional/choice emission | `test/types/exhaust.nim`, `test/types/checker.nim`, `test/library/options.iv`, `shapes.iv`, `test/backend/runtime.nim` choice/optional codecs. Preserve tags and padding semantics without assuming old emitters conform to all spec ABI clauses. |
| Generics, specialization, compile-time evaluation | `src/ir/monomorph.nim`, `eval.nim`, `lower.nim`; `src/opt/engine.nim` candidate contracts | `test/parse/generics.nim`, `test/ir/monomorph.nim`, `test/ir/eval.nim`, `test/opt/engine.nim`, `benchmark/generic.iv`, `known.iv`. Cross compilation must never run target binaries for eval. |
| Ownership, borrowing, regions, releasing parameters | `src/types/escape.nim`, `checker.nim`, `src/backend/native/escape.nim`; emitter cleanup/lifecycle; `memory.c`, Zig library/storage | `test/types/borrow.nim`, `escape.nim`, `test/backend/escape.nim`, `test/native/escape.iv`, `test/library/memory.iv`, `heap.iv`, `regions.iv`, `resource.iv`. Preserve failure/early return cleanup and release ordering, including callbacks/native boundaries. |
| Issues/errors/trails/panic | IR failure/control flow, C failable/error representation, `trace.c`, Zig library/service, `lib/issue.iv`, `trace.iv` | `test/library/issue.iv`, `spans.iv`, `test/ir/lower.nim`, `test/execute.nim`, `benchmark/failure.iv`. `specs/abi.md` specifies context/status/result/trail ABI, but C emitter currently uses error-pointer+value failable structs and direct return signatures. Treat ABI conformance as unresolved, not a proven shared C/Zig ABI. |
| Foreign C ABI/callbacks/header binding | `src/interop/bind.nim`, `expand.nim`, `src/sema/link.nim`; C convention and Zig functionConvention; `specs/abi.md` | `test/interop/bind.nim`, `expand.nim`, `fixtures/native.h`, `.c`, `.cpp`, `callbacks.iv`, `unbindable.h`; `test/library/dylib.c`, `.iv`, `test/cli/link.nim`. Built-in binding is a limited line parser; injectable BindProvider can supply Clang AST. Clang discovery does not prove full header parsing. Validate aggregate passing, callback conventions, symbol identity and C++ linkage separately. |
| Inline assembly, system calls, native registers | `src/backend/native/machine.nim`, `escape.nim`, `src/backend/asm/emitter.nim` and emitter assembly paths | `test/backend/machine.nim`, `test/backend/asm/emitter.nim`, `test/native/machine.iv`, `.golden`, `test/native/arch.c`, `test/parse/native.nim`. Preserve constraints, clobbers, side effects and platform-specific syscall ABI. |
| SIMD, CPU dispatch, atomics | `src/opt/arch.nim`, `vector.nim`, `substrate.nim`, `arch.h`, `copy.c`, native service CPU code, `lib/simd.iv`, `cpu.iv`, `atomic.iv` | `test/opt/arch.nim`, `test/backend/substrate.nim`, `test/backend/c/copy.nim`, `test/library/simd.iv`, `atomic.iv`, `test/platform/language.mjs` architecture inspection (stale). Preserve overlap-safe transfer, feature guards, FP order and memory ordering. |
| Tasks/concurrency/cancellation/IPC | `src/concurrency/backend.nim`, native service C, Zig service; `lib/task.iv`, `thread.iv`, `poll.iv`, `ipc.iv` | `test/concurrency/backend.nim`, `test/library/cancellation.iv`, `deadlines.iv`, `broadcast.iv`, `atomic.iv`, `poll.iv`, `ipc.iv`, `test/completion/race.zig`. Linux epoll/Windows IOCP candidates; other hosts threaded fallback; kqueue not evidenced. |
| Files, streams, processes, networking/TLS/HTTP | Native service and storage/stream/json/http C headers; Zig equivalents; `lib/file.iv`, `process.iv`, `net.iv`, `dns.iv`, `tls.iv`, `http.iv` | `test/library/storage.iv`, `stream.iv`, `positioned.iv`, `process.iv`, `pipes.iv`, `socket.iv`, `services.iv`, `tls.iv`, `test/library/tls.mjs`. Service availability is target-specific; cannot promise hosted calls on freestanding/WASI merely because lib modules type-check. |
| JSON codecs, sequences, tables, text | `src/backend/c/runtime.nim` generates type-dependent codec wrappers; `json.h`, `runtime.h`, Zig library/shim; `lib/json.iv`, `codec.iv`, `sequence.iv`, `table.iv` | `test/backend/runtime.nim` generated JSON record/sequence/optional/choice checks; `test/library/codec.iv`, `encoding.iv`, `collections.iv`, `mapping.iv`, `heap.iv`. Replace C field expressions/type printer dependency with descriptors or LLVM wrappers; preserve failures and allocation ownership. |
| Crypto/compression/GPU | C runtime/service imports libsodium/zlib/platform crypto and bundled BLAKE3; Zig library/services; SPIR-V and native Vulkan paths above | `test/library/crypto.iv`, `blake.iv`, `compression.iv`, `checksum.iv`, `device.iv`; GPU optimization fixtures. Actual Vulkan device parity remains unverified; preserve guarded fallback. |
| Packages/releases | `src/pkg/{resolve,lock,fetch,cache,hash,vendor,registry,surface,lint}.nim`, `src/build/release.nim`, tools/installers | `test/pkg/*.nim` including publish/local/scaling; `test/build/release.nim`, `artifact.nim`, `project.nim`, `test/cli/registry.nim`. Preserve hashes, lock identity, offline/vendor behavior, multiple products and native runtime sidecars. |

### Explain and caches

`--explain` is currently presentation/progress, not an LLVM pass dump. `src/cli/main.nim` turns it into verbose operation display for builds/tests/benchmarks and explicit explain state for toolchain/package commands. `src/cli/display.nim` newOperation/update displays detailed reasons only when explain or always-show-detail is enabled; display(verbose) renders detailed Progress events. Both backend drivers publish substrate decisions (implementation/stage/reason), compilation/cache progress. Tests: `test/cli/display.nim`, `main.nim`, `runner.nim`, `test/build/execute.nim`, `test/backend/substrate.nim`, `test/opt/engine.nim`. LLVM should report resolved target/data layout, runtime providers, rejected/fallback specializations, tool/sysroot/linker and cache hit/miss reasons through this interface.

Existing cache layers are distinct:

* `src/build/query.nim`: in-memory input digests and dependency queries; fingerprint scans nim/js/mjs/zig/h/c/iv/json. LLVM `.ll`/`.bc` inputs would currently be omitted.
* `src/build/planner.nim`: canonical JSON signature with revision; payload integrity digest in stage `.plan` files (`test/build/planner.nim`, `query.nim`).
* `src/build/project.nim`: project directory digest, compiler executable digest, backend, target, entry, mode, semantic flag and serialized Native options; `build.json` publication reuse (`test/build/project.nim`, `cache.nim`). Verify external tool/sysroot/transitive native-header changes invalidate this layer; do not assume the backend's own cache compensates when project reuse skips it.
* `src/pkg/cache.nim` / `src/build/cache.nim`: keyed receipts and output-content hashes; tool digest caching. C driver's fast cache hashes command/compiler stamp/generated source/service bytes and artifact digest; excludes Vulkan and configurations with external libs/includes/supply headers. Its non-fast path has separate object/link handling (`test/backend/c/driver.nim`).
* Zig driver uses local/global Zig caches (`FOO_CACHE_HOME`, Zig cache variables). Launcher and driver pin cache paths to backend version. `src/test/cache.nim` hashes normalized file identity/name/line under backend/mode directories; test output path identity is not a complete validity key (`test/runner.nim`).
* Bindings hash header content/include paths/flags; fallback key does not represent complete transitive preprocessing/tool/target state. Package content caches, test caches and native bootstrap embedded-byte stamps must remain distinct.

Proposed LLVM keys include compiler/runtime ABI revision, normalized target descriptor/catalog digest, triple/DataLayout, CPU/features/deployment, mode/checks/optimization pipeline, exact LLVM/Clang/LLD/builtins/sysroot digests, source/IR and transitive native inputs, flags, linked objects/libraries, profiles, sanitizers and output kind. Verify integrity as well as identity. Avoid deleting historical caches until compatibility rules are explicit.

## Dependency inventory and acquisition

Verified actual tree (upstream revisions below are provenance recorded by vendor READMEs, not independently byte-matched to remote repositories):

| Dependency | Actual repository content | Runtime/build external requirement |
| --- | --- | --- |
| BLAKE3 | `vendor/blake3/c/blake3.c`, dispatch/portable/SSE2/NEON sources and headers/license; README pins 1.8.7, commit f3149ec5bb5449af877ba20377a11008ff499fa2 | C driver compiles portable+dispatch and architecture sources for crypto; disables SSE4.1/AVX2/AVX512. Keep dispatch behavior rather than assuming host feature set. |
| Vulkan-Headers and volk | `vendor/vulkan/include/vulkan/vulkan_core.h`, `vk_platform.h`, `volk.c`, `volk.h`, licenses. README pins headers c46850864f4661461b0f6cb9922c058ffea4915e and volk 0dc3ce00bf98b9f0b6fe708ca0f7eb74e2830173 | Driver compiles volk against vendored includes; Vulkan loader/vendor driver supplied by OS. Not a complete Vulkan SDK or installed GPU driver. |
| SPIR-V headers | `vendor/spirv/spirv.h`, license, README commit 86f980c731e62ae4eaf383d320449d71687936bf | Definitions only; not proof of bundled validator, optimizer or LLVM SPIR-V translator. Current kernel emitter writes words itself. |
| MoltenVK | `vendor/moltenvk/MoltenVK/`, shader converter, Xcode/CMake projects, scripts, ExternalRevisions, license | Source tree exists; no `.a`/`.lib`/`.dll` was found by binary inventory for it. Building/installing Metal/Vulkan bridge and Apple SDK/dependencies is extra work. Bundling source does not make macOS Vulkan operational. |
| libsodium | `vendor/libsodium/windows-x64/include/`, `libsodium.lib`, license/README; provenance 1.0.22 MSVC v143 static archive | Windows x64 supplied by `src/toolchain/native.nim`; other hosts/architectures need compatible package/lib. |
| zlib | `vendor/zlib/windows-x64/include/zlib.h`, `zconf.h`, `zlib.lib`; README 1.3.1 vcpkg x64-windows-static with archive/library hashes | Same architecture restriction; preserve static runtime/CRT compatibility. No vendored cross-platform zlib source was established. |

`src/toolchain/manager.nim` and `tools/toolchain.mjs` detect/install pinned Zig 0.16.0, download ziglang.org release index/archive, validate size/checksum and executable, extract and record capability components/probes. `FOO_HOME`, old `.foo`/`.tratio` homes and project artifact paths affect discovery. Toolchain levels are base/system/machine/hardware; hardware requires QEMU or `FOO_SIMULATOR` and on Windows is a WSL workflow. Presence of receipts here was observed but validity was not checked.

`src/toolchain/native.nim` probes selected compiler with header/library paths. On native Debian/Ubuntu it uses apt-cache candidate metadata, apt-get download and dpkg-deb extraction into toolchain cache for libsodium-dev, zlib1g-dev and libcurl4-openssl-dev plus selected curl runtime package. This is unprivileged provisioning, not a fully pinned universal sysroot. Curl runtime is copied as libcurl.so.4 with $ORIGIN rpath; transitive system dependencies remain a deployment risk. Cross targets deliberately skip this host provisioning. Other platforms/custom imports require supplied development packages/includes/libs.

`src/toolchain/doctor.nim` checks Clang/CLANG header tooling, C compiler and native headers; it shares provisioning behavior. `src/interop/bind.nim` has a clangPath option/provider seam but default binding is the limited parser described above. Do not replace header discovery with an unsupported assertion that libclang is already vendored.

Platform links in `src/backend/native/service.nim`: Windows ws2_32/dnsapi/iphlpapi; macOS resolv; Linux pthread/resolv/dl. C HTTP runtime uses Windows WinHTTP/ws2_32 versus curl elsewhere (`test/backend/runtime.nim`). Native TLS/crypto/platform services can rely on further platform APIs: audit `service.c` preprocessing per target before setting supported-provider manifests. `tools/native.mjs` searches NIM_BIN/choosenim/PATH (error text requests Nim 2.2.12), needs llvm-rc on Windows, and managed Zig for Linux ARM64 bootstrap. `package.json` has only editor-test npm devDependencies, no LLVM binding/runtime dependency. Inno Setup, Linux packaging tools, signing providers, Rust/C++ comparison compilers and editor test downloads are ancillary dependencies, not LLVM code generators.

## Existing commands and test disposition

These are current commands to schedule in later implementation batches; **not run in Batch 0**. The native runner compiles each suite using Nim, `--path:<root>`, isolated nimcache/output/temp and FOOTESTID, and Clang on Windows, then executes it. It groups imports from five suites and serializes C WASI/threads tests. A single test can be run with `nim c -r --path:. test/<path>.nim` with explicit isolated output/cache/environment for concurrent runs.

| Commands / exact scripts | Classification | Proposed disposition |
| --- | --- | --- |
| `npm test`: `node test/library/check.mjs && node test/native/run.mjs`; `node test/run.mjs` imports native runner; `npm run test:native` / `test:build` | Mixed semantic/build/integration umbrella, not backend independent as a whole | Retain runner and add LLVM into executable parity matrix. Never treat npm test as full target execution coverage. |
| `test/suites/syntax.nim`; `test/{lex,parse,ast,sema,types,fmt,diag}/*.nim`; `test/ir/*.nim` | Primarily language semantics/IR, with layout/native target dependencies | Retain; separate target-aware layout checks. `test/types/borrow.nim`, `layout.nim`, `test/parse/machine.nim` remain essential, not obsolete backend tests. |
| `test/suites/engine.nim`, `build.nim`, `cli.nim`, `package.nim` | Mixed grouped tests; engine imports both emitter tests and runtime/substrate tests | Retain grouping, migrate imports only after replacement tests land; never empty suites to obtain green status. |
| `test/backend/c/{emitter,driver,execute,cross,wasi,threads,copy}.nim`; `test/backend/zig/{emitter,driver,shim}.nim` | Old source-generation/driver tests | Add LLVM counterparts. Repurpose execution/cross/copy/WASI/threads into parameterized behavior/artifact tests. Eventually delete only C/Zig source-spelling/driver assertions after parity and removal gates; keep native C runtime tests. |
| `test/backend/{runtime,service,substrate,escape,machine,icon}.nim`, `test/backend/asm/emitter.nim`, `test/concurrency/backend.nim`, `test/opt/{arch,engine,profile}.nim` | Shared contracts mixed with generated-C assumptions | Retain behavior; repurpose runtime string assertions into ABI/runtime execution checks and keep retained-C fragment assertions where useful. Test selection/explain and fallback failures for LLVM. |
| `test/build/{artifact,cache,compiler,config,execute,files,native,options,planner,portable,project,query,release,tasks}.nim` (portable is `.iv`) and `test/cli/*.nim` | Build/CLI/integration/release | Retain and extend backend enum/toolchain receipts, products, link formats, cache invalidation, progress/explain and hooks. |
| `test/pkg/*.nim`, `test/interop/{bind,expand}.nim`, `test/toolchain/{doctor,manager,native}.nim` | Packages, FFI, acquisition/provisioning | Retain; update tool identities/probes; preserve C ABI tests even when old emitters retire. |
| `npm run test:library`: checker then `node bin/foo.mjs test lib --backend c`; `node bin/foo.mjs test test/library --backend c` and `--backend zig`; `node bin/foo.mjs test lib --backend zig` | First script naming/type-check plus language library runtime tests | Retain semantic sources; add `--backend llvm` after CLI support, dev/release parity. Use library project requirements/fixtures. `test/library/check.mjs` invokes launcher check, so validate absence of write/provision side effects before calling it read-only. |
| `node test/library/tls.mjs`, `test/completion/server.cjs`, overflow.c/race.zig fixtures; `test/library/dylib.c` | Environment/service/foreign-language integration | Retain TLS/server/dylib/C ABI; repurpose old-backend completion comparisons, do not silently drop races/overflow checks. |
| `node test/platform/gates.mjs [existing evaluation aggregate allocator hardware arm riscv]` | Linux/WSL cross/hardware integration; can install hardware toolchain | Retain fixtures/linker/ELF/QEMU checks; add LLVM and keep c/zig baseline until parity. Run on Linux with matching FOO_BIN and simulators. |
| `node test/platform/language.mjs` | Linux native/FFI/atomic architecture gate, currently stale JS compiler imports from `.artifacts/compiler/src/...js`; invokes llvm-objdump-14 | Repurpose to current native CLI/API and pinned objdump. Treat current command as unverified runnable, not a passing Nim gate. |
| `npm run test:docs` -> `node test/docs/run.mjs`; `test/docs/{status,snippets}.nim`; `test/lsp/server.nim`, `node test/lsp/live.mjs`, `test/location.mjs` | Documentation/language-service integration | Retain; fix backend-specific examples only when corresponding behavior changes. |
| `npm run test:editor` -> editor run/snapshots/theme/probe scripts; `npm run test:host` -> `test/editor/editor.mjs` | Editor/platform-independent syntax plus editor-host integration | Retain; no emitter-driven deletion. Host integration has editor/environment dependencies. |
| `npm run check` -> `node tools/native.mjs --check` | Nim static check, writes cache/directories | Run later, not read-only Batch 0. Retain compiler-bootstrap check. |
| `npm run benchmark`; `node bin/foo.mjs benchmark --backend c` / `--backend zig`; `npm run benchmark:report`; `node benchmark/compare.mjs` | FOO semantic/runtime timing plus old C/Zig/Rust/C++ reference baselines | Add LLVM results with tool/target/runtime/mode identity; keep comparisons and historical JSON, reject performance gains achieved by dropping checks. |
| `npm run build`, `source:pack`, `binaries`, `build:installers`, signing scripts; `test/build/release.nim`, `artifact.nim`, `test/pkg/publish.nim`; `npm run registry:standard:check` | Package/distribution/release/catalog | Retain; exercise clean installation/offline and target-specific assets before old managed toolchain removal. Signing/publishing is not a routine audit check. |

## Proposed architecture and version policy

1. Keep Nim frontend/typed IR and language-level optimization/evaluation. Add `src/backend/llvm/` target lowering, ABI/layout, instruction emission, verification and driver modules. Share backend-independent build result/options/progress and target resolution; do not duplicate project/package policy inside the driver.
2. Start with textual LLVM IR plus a pinned command-line verification/object pipeline (or a narrowly versioned LLVM C API shim if measurement justifies it). Record exact module triple/DataLayout. Avoid embedding an unversioned C++ LLVM ABI into Nim. Verify modules before optimization and after transformations in validation builds.
3. Use semantic-width SSA integers and separately specified ABI storage; explicit extension/truncation, bounds and overflow checks. Define layout/foreign ABI lowering centrally using target rules and probes. Resolve the existing spec/emitter ABI mismatch before exporting a supposedly stable LLVM ABI. Either preserve measured legacy compatibility or version an intentional break with adapters; a migration must not silently change it.
4. Extract C service/runtime sources into reproducibly compiled target objects using managed Clang, and replace generated type-dependent wrappers with LLVM wrappers or descriptor-driven runtime operations. A complete C/Zig **backend** migration does not imply banning C vendor code, user C imports or Nim's bootstrap C output. If removal of every C runtime implementation is a later goal, give it its own parity program.
5. Keep SPIR-V kernel emission and Vulkan service as a separate device path initially. LLVM CPU lowering must preserve GPU dispatch/fallback and recorded selection reasons. An LLVM-based GPU compiler would be a separate validated migration.
6. Resolve target tool bundles explicitly: clang, opt/verification tooling, llc or LLVM API, appropriate LLD flavor, llvm-ar/ranlib/objdump/rc, compiler-rt builtins and optional sanitizer runtimes; libc/SDK/CRT/sysroot and runner are independently versioned components. Native C/C++ and asm use the same target identity as FOO objects.

**Proposed policy, not an installed dependency:** choose one exact LLVM/Clang/LLD patch release in Batch 1, with LLVM 18.1.3 as an initial baseline candidate because that is the Clang observed locally. This is not a claim it is the latest or suitable for every target. Qualify the candidate against all matrix rows and interrupt/object format requirements; if it fails, choose another exact stable release before committing IR/API contracts. Ship one tested major line per FOO release, no arbitrary PATH major acceptance and no automatic latest upgrades. Use matching compiler/tool components, lock SHA-256 archives and component files, source URLs/licenses, target support manifest and ABI revision. Track sysroots/SDK minimums and thread-WASI variants separately. Allow an explicit developer override only with reported identity and isolated cache; supported releases use managed versions. Preserve Nim 2.2.12 bootstrap expectations separately. Do not borrow Zig's bundled sysroots invisibly and then remove Zig.

## Migration graph and batch gates

Dependency graph: **0 → 1 → 2 → 3 → 4 → 5**; from 5 branch to **6 hosted**, **7 WASI**, **8 freestanding/hardware**, **9 GPU/SIMD/concurrency**; **10 integration/release** requires 6+7+8+9; **11 retirement** requires 10 and all parity evidence. Some runtime extraction can proceed alongside core lowering, but no branch may be dropped to declare completion.

| Batch | Work / prerequisites | Pass/fail gate |
| --- | --- | --- |
| 0 | This evidence inventory | Pass if current implementation/tests/dependencies and target gaps are cited; fail if host-only support is represented as complete migration. No implementation edits. |
| 1 | Baseline characterization, target manifest, exact LLVM qualification, ABI decision and reproducible managed tools; requires 0 | Both legacy suites have recorded results/skips on required hosts; tool hashes/version rejection and isolated cache verified; concrete supported/unverified targets and ABI probes signed off in repo. Fail on undocumented spec/implementation mismatch or missing sysroot plan. |
| 2 | LLVM backend interface/target layout/verifier/object plumbing; requires 1 | Valid minimal objects for ELF/COFF/Mach-O/wasm with target layouts and deterministic diagnostics; deliberate invalid IR rejected; legacy unchanged. No claim of executable runtime parity yet. |
| 3 | Core values/control flow/records/choices/optionals/generics/eval/calls and checked widths 1–128; requires 2 | Differential semantic execution and layout fixtures versus measured baseline; full width boundary/overflow/zero/shift checks in dev/release; deterministic specialization and cross-eval. Fail on poison-driven behavior or host-derived cross layouts. |
| 4 | Runtime ABI, memory/regions/cleanup/releases/errors/trails and generated wrappers; requires 3 | Borrow/escape/failure/cleanup and library ownership tests pass; FOO call/error ABI probes and intentional compatibility policy verified; no Zig-only runtime dependency hidden in LLVM builds. |
| 5 | C ABI/header binding/native fragments/assembly plus executable/static/shared link products; requires 4 | C callback/aggregate round trips, native C/C++ objects, library consumers and product ordering pass; target-compatible linker scripts/exports/icons/rpaths checked; unsupported conventions diagnose. |
| 6 | Hosted Linux GNU/musl, Windows, macOS runtime/service/sysroot support; requires 5 | Actual host execution for supported architectures or explicit cross-artifact plus separate runner gate; files/process/net/TLS/HTTP/crypto/compression/dylib cleanup pass; clean deployed executable resolves all declared runtime deps. Spec-only presets must be implemented or explicitly dispositioned. |
| 7 | WASI and threaded WASI plus wasm runtime-none; requires 5 | Inspect imports/features/memory and run compatible runner; atomic/task workers genuinely execute for threads. Runtime-none module has no hosted imports. Existing wasm-magic checks alone fail this gate. |
| 8 | AArch64/RISC-V boards, startup/interrupt/naked/feature/MMIO support; requires 5 | ELF entry `_start`, load segments and linker maps pass, both QEMU serial fixtures execute, unsupported interrupt combinations reject; no hidden libc/compiler helper imports. Capability receipts/WSL restrictions retain truthful diagnostics. |
| 9 | CPU SIMD/dispatch/atomics/tasks and GPU kernel/host integration; requires 5 plus relevant 6/7/8 environments | Memory-order/race/cancellation/overlap and feature fallback tests pass; generated instructions inspected with pinned objdump; SPIR-V validated and representative Vulkan dispatch executed with fallback/error parity. Missing GPU hardware is an explicit unresolved gate, not success. |
| 10 | Cache/explain/test/benchmark/watch/package/bootstrap/distribution transition; requires 6–9 | LLVM works through all commands/products; keys invalidate on tool/runtime/sysroot/input changes and artifacts are integrity checked; explain reasons reproducible; clean online/offline installation, archived vendor licenses and sidecars, release packages tested; benchmark checks retained. |
| 11 | Default switch and C/Zig emitter/tool retirement; requires 10 | Entire support matrix has parity or an explicit approved versioned scope change; release rollback exists; only now remove obsolete emitters/source-string tests and Zig downloads/cache policy. Retained C runtime/FFI/vendor build tests still pass. No empty test files/suites. |

## Risks and unresolved work

A simplistic host-only LLVM implementation would lose managed cross libc/CRT support; WASI imports/shared-memory workers; freestanding board startup/link scripts; interrupt/naked/register semantics; GPU SPIR-V/Vulkan dispatch; C ABI callbacks/native snippets; scope cleanup/error traces; generated JSON codecs; feature-safe SIMD/task fallback; static/shared/release packaging and truthful cache/explain behavior.

LLVM object generation alone supplies neither OS APIs nor libc/SDKs, Vulkan drivers, QEMU, threaded-WASI runner, board initialization, signing or package distribution. Wide integer division/atomic lowering may introduce compiler runtime calls even in nominal runtime-none modules; inspect unresolved symbols per target and either supply approved builtins or reject the operation. Platform sanitizer runtimes require separate qualification. Windows arm64 cannot reuse bundled x64 sodium/zlib; Apple MoltenVK source is not a ready binary. Apt native provisioning is host-specific and does not constitute a cross sysroot.

Open evidence gaps to close in Batch 1: exact ABI conformance and symbol/call/layout compatibility of the legacy emitters; end-to-end macOS/Windows arm64; missing musl-arm64/macOS-x64 presets; advanced descriptor/catalog implementation status; runtime provider availability per WASI variant; actual threaded WASI execution; AArch64 interrupt contract; complete integer-width/conversion coverage; reproducible MoltenVK runtime acquisition; current GPU device test coverage; stale JS platform gate; transitive external native input/cache invalidation. Test presence and historical release directories must not be substituted for fresh results from the current working-tree baseline.


---

# Batch 2 integration addendum

The preceding audit describes the original C/Zig baseline. The following inventory includes the LLVM slice and core work integrated into this workspace. Historical statements above about CLI backend selection apply to that baseline.

# C/Zig to LLVM migration inventory

Evidence snapshot: repository 0.8.1 plus the LLVM vertical slice and Batch 2 work now integrated in this workspace. A path or preset is evidence that an implementation/test exists, **not** proof that it executes on every listed platform. Only the Windows x64 runs recorded in the Batch 2 differential report have been executed here. No cross runner, package publication, installation, GPU, or benchmark gate was run for this audit.

## Compiler and build map

| Responsibility | Concrete implementation | Existing checks |
| --- | --- | --- |
| Launch and CLI | `bin/foo.mjs`, `tools/native.mjs`, `src/main.nim`, `src/cli/main.nim` | `test/cli/`, `test/suites/cli.nim` |
| Parse, resolve, type, borrow/escape check, compile-time expansion | `src/build/compiler.nim`, `src/parse/parser.nim`, `src/sema/resolver.nim`, `src/types/checker.nim`, `src/types/coerce.nim`, `src/types/escape.nim`, `src/ir/eval.nim` | `test/parse/`, `test/sema/`, `test/types/`, `test/ir/eval.nim` |
| Typed lowering, specialization, shared optimization and reachability | `src/ir/node.nim`, `kind.nim`, `lower.nim`, `valid.nim`, `monomorph.nim`, `reach.nim`, `src/opt/` | `test/ir/`, `test/opt/` |
| Backend interface | each `src/backend/{c,zig,llvm}/driver.nim::build(Module,mode,outDir,Native,sourceFile,progress)`; `src/build/options.nim::Native` | `test/backend/{c,zig,llvm}/`, `test/build/` |
| Generated source | `src/backend/c/emitter.nim`, `src/backend/zig/emitter.nim`, `src/backend/llvm/emitter.nim` | emitter tests and `test/backend/llvm/core.nim` |
| Runtime and native fragments | `src/backend/c/{runtime.nim,runtime.h,json.h,arch.h,http.h,storage.h,stream.h,memory.c,trace.c,copy.c}`, `src/backend/zig/{shim.nim,library.zig,storage.zig,stream.zig,service.zig}`, `src/backend/native/{service.c,service.h,gpu.c,vulkan.c,escape.nim,service.nim,icon.nim}` | `test/native/`, `test/library/`, `test/backend/c/copy.nim` |
| Backend/substrate selection | `src/backend/substrate.nim`, native escape/interop modules, `src/interop/` | `test/interop/`, native and platform tests |
| Compile, link, process execution | drivers; `src/build/project.nim`, `src/build/execute.nim`, `src/targets/presets.nim` | `test/build/`, `test/targets/presets.nim`, platform gates |
| Managed tools | `toolchain.json`, `tools/toolchain.mjs`, `src/toolchain/{manager,native,doctor}.nim`, `src/pkg/cache.nim` | `test/toolchain/{manager,native,doctor}.nim`, `test/pkg/cache.nim` |
| Cache | project `buildIdentity` includes project/compiler digests, backend, target, entry, mode, native options and semantic policy; LLVM adds queried Clang/LLD identities, effective triple/data layout and optimization policy | `test/build/cache.nim`; LLVM slice project-cache assertion |
| Release/package | `src/build/release.nim`, `src/pkg/`, `tools/{source,binaries,build,sign}.mjs`, `tools/build.ps1`, `installers/`, `package.json` files list | `test/build/release.nim`, `test/pkg/`, `test/suites/package.nim` |
| Tests/benchmarks | `src/test/runner.nim`, `src/benchmark/runner.nim`, `test/native/run.mjs`, `test/library/check.mjs`, `tools/benchmark.mjs`, `benchmark/compare.mjs` | `test/runner.nim`, `test/benchmark/runner.nim`, `test/library/` |
| `--explain` | CLI parses `--explain` as verbose progress; `src/cli/display.nim::Operation` exposes otherwise hidden detail; build drivers/project report reachability, compilation, cache and semantic decisions | CLI/display/build tests; LLVM `llvm.json`, `.command`, `.diagnostics`, `source.json` |

The actual compiler is Nim; `specs/toolchain.md` still says TypeScript/JavaScript and is stale. JavaScript launch/build tools wrap the native compiler. This discrepancy is an audit finding, not a new architecture requirement.

## Targets and behavior that a host-only backend loses

Every preset below occurs in `src/targets/presets.nim`. Execution beyond Windows x64 is **unverified in this session**.

| Surface | Repository evidence and existing behavior | LLVM prerequisites beyond core IR |
| --- | --- | --- |
| Hosted Linux x64/v3, ARM64, musl x64 | `linux-x64`, `linux-x64-v3`, `linux-arm64`, `linux-musl-x64`; C system compiler or managed Zig; ELF dead stripping in C driver | target machine, libc/sysroot, compiler runtime, LLD ELF and platform services; glibc/musl distinction |
| Windows x64/v3, ARM64 | corresponding presets; MSVC/CRT selection, `zig libc`, Clang includes, `.exe/.dll/.lib`, resources/debug/link options | MSVC ABI classifier, SDK/CRT discovery, COFF resources/unwind/debug; ARM64 runtime qualification |
| macOS ARM64 | `macos-arm64`; driver framework/rpath/dead-strip support; MoltenVK source tree | Darwin ABI, SDK, Mach-O linker, frameworks/signing/package qualification |
| WASI/threaded WASI | `wasi`, `wasi-threads`; `test/backend/c/wasi.nim`, `threads.nim`, cross tests; doctor checks `wasmtime` | WASI sysroot, wasm-ld/imports/exports, thread atomics/shared memory and runner; hosted POSIX service assumptions must be removed |
| Freestanding Wasm/AArch64/RISC-V | `wasm-freestanding`, `arm64-freestanding`, `riscv64-freestanding`; `runtime:none`; `test/platform/fixtures/{arm,riscv}.{iv,ld}` | startup, stack, section/link scripts, memory map, no CRT, compiler builtins, emulator/hardware |
| Startup/interrupt/exact hardware access | frontend attributes `start`, `naked`, `interrupt`, `target_feature`, volatile; `test/parse/machine.nim`, platform hardware gates | target-specific interrupt ABI, naked restrictions, asm constraints, MMIO ordering/alignment |
| GPU/SPIR-V/Vulkan | `src/opt/gpu.nim`, native GPU/Vulkan sources, vendor SPIR-V headers, `lib/{gpu,vulkan}.iv`, library GPU fixtures | shader lowering/tool validation, device resource ABI, vendor drivers/loader; LLVM host code alone cannot replace SPIR-V generation |
| Runtime-free/static/shared/custom link | `Native` fields for kind/exports/script/rpath/libs/frameworks/sources/objects; both old drivers implement these | distinct entry/export ABI, compiler runtime selection, archive/shared linking and no implicit hosted support |
| Foreign C ABI | `src/interop/`, `use c` headers and declared conventions; C compiler macros for c/system/stdcall/fastcall/vectorcall/thiscall; Zig equivalents | ABI classification for aggregate/wide args/returns and callbacks, varargs, calling conventions, exported symbols |
| Inline assembly/SIMD/dispatch | native substrate and vector IR (`Splat`, `Shuffle`, `Gather`, `Scatter`, `Select`, `Reduce`), `src/opt/{arch,vector}.nim` | checked lane lowering, qualified feature sets, asm constraints and dispatch evidence |

C-specific contracts include explicit checked integer helpers, addressable widened storage for odd widths, `__int128`, C11 atomics, recursive equality/order helpers, generated C codec shapes, struct offsets/alignment, memory-region lists, shared native service fragments, platform dead-strip and bundled-library selection. Its emitter rejects scoped allocation/Defer in multiple-block IR and nested packed fields. Zig-specific contracts include actual arbitrary-width integers, error unions/optionals/slices, `@sizeOf/@alignOf`, allocator/shim support, managed version pins, ReleaseSafe compilation and selected scalar compilation flags, native extern conventions and generated callbacks. These physical representations cannot be copied blindly into a stable FOO/foreign ABI.

## Language and library migration coverage

The detailed typed-representation mapping is `specs/llvmcore.md`; fixtures and per-backend failures are retained under `test/backend/llvm/fixtures/` and `cases.json`.

| Feature | Current lowering/runtime | Concrete checks to retain/migrate |
| --- | --- | --- |
| Integers 1–128, signedness, comparisons, widening, checked arithmetic | checked frontend types -> typed arithmetic/Convert; C helpers versus Zig scalar widths | `test/types/coerce.nim`, `test/ir/valid.nim`, integer differential partitions plus `wide.iv`, `overflow.iv`, `division.iv` |
| Shifts/bit updates | no shift opcode in `src/ir/kind.nim`; machine bit/native operations are separate capability contracts | `test/parse/machine.nim`, platform hardware gate; LLVM machine lowering remains separately qualified |
| Records/layout/reflection | frontend field ordering/layout attrs, IR Struct/ExternStruct/PackedStruct; compile-time eval and runtime Reflect | `test/types/layout.nim`, `test/ir/eval.nim`, `test/library/layout.iv`, `values.iv`, `packed.iv` |
| Optionals/choices/generic types/functions | frontend checking + monomorphize + reach; wrapper injection, tags/active payload | `test/types/checker.nim`, `test/ir/{lower,monomorph,reach}.nim`, `test/library/{options,patterns,derive}.iv`, `values.iv` |
| Decimal/bool/text/bytes/sequences/function values | LLVM scalars/storage/direct and indirect calls; runtime library operations | `test/library/{algebra,collections,binary,ordering}.iv`, `control.iv`, `decimals.iv`, `sequences.iv` |
| Ownership/move/borrow/releasing/temporary cleanup | common checker/escape analysis and explicit cleanup CFG; residual Defer; runtime allocations | `test/types/{borrow,escape}.nim`, `test/library/{view,memory}.iv`, `cleanup.iv`, `exits.iv`, `pointers.iv`, `arena.iv` |
| Issue trails | typed failable values, Trace IDs/spans, `lib/issue.iv` records/sequences | `test/library/issue.iv`, `issues.iv`; raw LLVM trace-boundary qualification |
| JSON codecs | C runtime codec generator and Zig runtime JSON; specialized typed externs | `test/library/{encoding,codec}.iv`, `codecs.iv`, sequence codec fixture |
| Tasks/concurrency | service/thread/task/atomic runtimes and typed effect edges | `test/backend/c/threads.nim`, `test/library/{atomic,cancellation,deadlines,broadcast}.iv`; future runtime batch |
| Files/process/network | service fragments, stream/http runtimes, platform APIs | `test/library/{pipes,ipc,http,console}.iv`, native service tests; future runtime batch |
| GPU/package/release | native GPU/Vulkan runtime, package/build/release modules | GPU library tests, `test/pkg/`, `test/build/release.nim`; future target/integration batches |

## Vendored versus externally supplied dependencies

Verified files: `vendor/blake3/c/blake3.h` and portable/dispatch/SSE2/NEON sources (README pins 1.8.7); `vendor/vulkan/include/vulkan/{vk_platform.h,vulkan_core.h}` (Vulkan-Headers pin in README); `vendor/vulkan/{volk.c,volk.h}` (separate pin/license); `vendor/spirv/spirv.h`; `vendor/moltenvk/` Objective-C++/C++ sources, Xcode/CMake/scripts and external revision references; `vendor/libsodium/windows-x64/{libsodium.lib,include/sodium.h}`; `vendor/zlib/windows-x64/{zlib.lib,include/zlib.h,include/zconf.h}`. **MoltenVK source presence does not establish that its external revisions or a usable prebuilt dylib exist.** Vulkan loader/vendor drivers are externally supplied.

`src/toolchain/manager.nim` and `tools/toolchain.mjs` pin Zig using `toolchain.json`/`foo.lock`, verify executable version, download archives and maintain capability receipts. `src/toolchain/native.nim` finds bundled Windows sodium/zlib; on Linux it probes system headers/libs and may use `apt-cache`/`apt-get download`/`dpkg-deb` to provision native files. C driver selects explicit compiler, `CC`, Windows Clang, `cc`, or managed `zig cc`; links system libs/frameworks and builds vendored fragments where needed. Header interop uses Clang/`CLANG`. `foo doctor` may provision/probe dependencies, so it is **not** a strictly read-only audit command and was not run. npm has no production package dependencies; development packages in `package.json` are editor test tooling. QEMU/wasmtime and OS SDK/CRT/headers/libraries are external requirements.

Observed installed tools: Nim 2.2.12 in the user's choosenim installation; Clang/LLD 18.1.3 selected through PATH; managed Windows Zig 0.16.0 at the version-verified user installation; Node 24.11.1. Linux archives in another cache do not establish a Windows tool installation. LLVM is currently externally selected, not automatically provisioned.

## Retained commands and test disposition

Run ordinary Nim files with `nim c -r --cc:clang --mm:refc --path:. <file>` on this Windows qualification host. Use a distinct `--nimcache` and `--out` per concurrent suite. The differential runner currently uses refc because a full imported-library compile exposed an ORC collector crash; this does not change FOO runtime semantics and is recorded as a compiler-host issue.

| Category | Exact commands/paths | Disposition |
| --- | --- | --- |
| C backend-specific | `test/backend/c/{emitter,driver,execute,copy,cross,wasi,threads}.nim` | keep now; migrate target/runtime behavioral fixtures; eventually retire source-spelling assertions only after replacement gates |
| Zig backend-specific | `test/backend/zig/{emitter,driver,shim}.nim` | keep now; repurpose ABI/runtime/shim contracts; retire generated-Zig syntax expectations only after parity |
| LLVM | `test/backend/llvm/{slice,optimization,core}.nim` | retain and expand; old entry-exit assertion updated to actual C/Zig hosted behavior |
| Language semantics | `test/lex/`, `test/parse/`, `test/sema/`, `test/types/`, `test/ir/`, `test/library/*.iv` | retain unchanged unless a differential proves a shared bug; run source fixtures through all backends |
| Build/integration | `test/build/{cache,release}.nim`, `test/targets/presets.nim`, `test/runner.nim`, `test/benchmark/runner.nim` | parameterize LLVM, keep cache/package/release expectations |
| Platform | `node test/platform/gates.mjs` (Linux; names `existing evaluation aggregate allocator hardware arm riscv`), `test/platform/language.mjs` | retain boards/link scripts/execution checks, add LLVM after target readiness; no host-only skip may count as pass |
| Package/release | `test/suites/package.nim`, `test/pkg/`, `test/build/release.nim` | retain; don't publish/sign as an audit check |
| Repository runners | `node test/native/run.mjs`, `npm test`, `npm run test:library`, `npm run test:docs` | run only appropriate gates; these are broad/mutating build checks, not read-only audit checks |
| Benchmarks | `node bin/foo.mjs benchmark --warmup 3 --iterations 20`, `node tools/benchmark.mjs`, `benchmark/compare.mjs` | retain baseline/sample/metrics format; establish LLVM correctness before performance gates |
| Editor/static tooling | editor tests and documentation/name checks | platform-independent where their runner permits; preserve backend selection syntax |

Batch 2 command: `nim c -r --cc:clang --mm:refc --path:. --nimcache:.artifacts/llvm-core/nimcache-refc --out:.artifacts/llvm-core/core.exe test/backend/llvm/core.nim`. `FOO_LLVM_CASE` selects one retained manifest case. `.artifacts/llvm-core/results.json` records every compiled/unsupported/run observation, exact output hex and process exit. Unsupported expectations fail when the actual reason changes or the backend begins supporting the case. Error contracts record backend-specific established diagnostic/exit differences explicitly.

## Proposed architecture/version policy and migration graph

Use the existing frontend, typed IR, specialization and semantic optimizer. LLVM emission owns target storage and checked operations/control flow, not parsing/types. Runtime C support may be compiled by Clang, but never contains generated FOO functions/control flow. All aggregate runtime exchanges use aligned pointer adapters with compile-time C size/alignment/offset assertions. Raw foreign exports/callbacks need a distinct target ABI classifier. Target data layout comes from the selected LLVM target machine; current layout implementation is qualified only for little-endian Windows x64 and must reject other targets.

During qualification record full actual Clang/LLD identities, triple, data layout and semantic-policy version in cache/explain artifacts. Current qualification baseline is LLVM 18.1.3 and Zig 0.16.0. Proposed release policy: pin one exact LLVM patch/tool archive per FOO release and host, verify archive hashes/licenses, use matching Clang/LLD/compiler-rt, and test upgrades as a complete toolchain. Do not advertise an arbitrary minimum-version range without CI evidence. Changes to runtime/layout/ABI/proof policy invalidate caches. Existing externally selected LLVM remains an explicit development option until managed packaging is implemented.

| Batch | Prerequisites | Pass/fail gate |
| --- | --- | --- |
| 0 audit/map | repository read-only inventory | all targets/runtime/ABI/test/toolchain surfaces have paths, verified/unknown status and migration owner |
| 1 vertical slice | 0 | typed arithmetic/calls executable, verifier at O0/O2, real target layout, CLI dispatch, tool identity/cache/error evidence |
| 2 core semantics | 1 | every retained shared core fixture passes C/Zig/LLVM where supported; exact bytes/exits/errors; frontend borrow/layout/specialization regressions; unsupported fixtures carry specific tested reasons |
| 3 ABI/runtime boundaries | 2 | aggregate/wide foreign calls/returns/callbacks, calling conventions, exports, stable layout, trail identities and allocator lifetime tests on target ABI |
| 4 hosted services/concurrency | 2+3 | files/process/network/task/thread/atomic suites; cleanup and failure paths; bundled/platform runtime dependency gates |
| 5 target matrix/runtime-free | 2+3; platform portions of 4 | each preset compiles/links and target execution runner passes; WASI threads/board startup/interrupt/asm/sysroots separately gated |
| 6 SIMD/GPU | 3+5; service infrastructure 4 | checked lane operations, feature dispatch, SPIR-V validation/device output parity; qualified device/driver runs |
| 7 managed toolchain/package/release | 3–6 target-specific closures | reproducible verified downloads, doctor, offline/cache reuse, library/executable releases, installation/run/signing gates |
| 8 optimization/performance/cutover | all advertised features above | differential suite remains green; benchmark evidence; remove only superseded generated-source assertions, then deprecate/remove old backends in a later authorized batch |

Critical risks: ABI mismatches hidden by C wrappers; odd-width versus storage-width overflow; LLVM poison on division/remainder/shift; padding leakage in equality/codecs; source-span loss; cleanup missed on CFG exits; functions borrowing temporary slice storage; unchecked attributes; missing compiler-rt wide division; target sysroot/CRT assumptions; source-only vendoring mistaken for installed dependencies; cache reuse after policy/tool upgrades; stale spec claims. A simplistic host LLVM emitter would lose every cross preset, runtime-free/hardware path, foreign aggregate ABI, GPU pipeline, release integration and most runtime services. Those losses must be explicit failing gates, never silently filtered tests.

## Batch 2 implementation and retained acceptance

The main workspace now contains the shared typed IR core LLVM emitter, layout
and pointer-runtime adapters. `specs/llvmcore.md` maps each lowering to frontend
representations and exact fixtures. Core qualification includes widths 1–128,
runtime arithmetic and decimal edge cases, aggregate/function/unit values,
relocation-bearing globals, specialization, layout/reflection, logical packed
comparisons, JSON/error behavior and ownership/cleanup exits. Shared lowering
uses the checker's actual reflection record for inline projections; static
initializers reuse its arbitrary-width range proof.

Run `./test/backend/llvm/acceptance.ps1` from the repository root. It requires
the installed Clang/LLD and managed Zig, installs nothing, and retains 16
prerequisite checks plus the complete 42-fixture, three-backend, two-mode
source matrix (252 observations) and 24 typed IR observations. Reports count
frontend rejections and concrete legacy restrictions separately from executable
results. Fixture hashes and every backend/mode row are verified before the
acceptance report can pass. `-VerifyReportsOnly` revalidates complete retained
reports; it requires every prerequisite to have passed and cannot validate a
filtered, stale or incomplete source matrix. `-Root` selects artifact storage
and `-Cache` allows serial reuse of a Nim compilation cache.

The qualified host is still Windows x64 with LLVM/LLD 18.1.3, Nim 2.2.12 and
Zig 0.16.0. Existing C/Zig tests remain intact. Their nested-packed, unit-parameter
and integer-entry restrictions, shared frontend rejections, typed block-argument
limitations, packed JSON runtime rejection and future ABI/platform requirements
are listed with concrete tests in `llvmcore.md`. Completing this core gate does
not qualify the separate target, runtime-free, native ABI, concurrency, GPU,
toolchain packaging or release gates above.
