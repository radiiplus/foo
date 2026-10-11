# LLVM core lowering contract

Batch 2 uses `src/build/compiler.nim` unchanged: parse/resolve/check, compile-time expansion, typed `src/ir/lower.nim`, specialization and semantic optimization. The driver validates that IR, applies existing reachability and `prepare`, then emits LLVM. No source syntax or typing rule is interpreted by the backend. Shared lowering now retains AST source spans, represents mutable projections consistently, and emits explicit wrapper coercions accepted by the existing checker and IR validator.

| Frontend/type representation | Typed IR | LLVM implementation |
| --- | --- | --- |
| Function signatures, specialized generic calls and callable types (`src/types/checker.nim`, `src/ir/monomorph.nim`) | Function.params/ret, Call.func/callee/args, Global function value | Direct/indirect internal LLVM calls, opaque function pointers; runtime function values receive LLVM wrappers with the internal ABI and pointer adapters. Zero-sized unit parameters are erased at the ABI boundary, while the frontend signature remains intact. |
| Mutable places, assignment, branch/loop lowering (`src/ir/lower.nim::lowerFunction`, nested `place`/`statements`) | Alloc slot, Load/Store, Jump/Cjump, Phi and block arguments | Entry-allocated typed storage, explicit edges; all merge sources read before destinations are written. |
| Integer signedness/width and permitted widening (`src/types/coerce.nim`) | Int/Uint 1–128, Add/Sub/Mul/Div/Remainder, Compare/Convert | Semantic-width overflow intrinsics and explicit panic branches; canonical extension to addressable 8/16/32/64/128-bit storage. No nsw/nuw, noalias, nonnull or range assumptions. |
| Decimals/booleans/bytes/characters/text | Float32/64, Bool, Uint8/32, constant Slice Uint8 | IEEE operations without fast math; byte bool at memory boundaries, i1 predicates; length-bearing UTF-8 text. |
| Records/optionals/choices/arrays/sequences/pointers (`src/ir/node.nim`) | Struct/ExternStruct, Optional, TaggedUnion, Array/Slice/Ptr; Construct/Extract/Index/Length | Target-sized storage/offsets from layout.nim; zeroed construction; checked indexing, active payload comparisons, pointer-only runtime marshaling. |
| Reflection and compile-time queries (`src/ir/eval.nim`) | Folded frontend constants, Reflect.typeArg | Folded queries remain frontend decisions; runtime reflection measures qualified target layout. C runtime asserts sizes, alignments and record offsets at compile time. |
| Borrow/move/release checking (`src/types/checker.nim`, `escape.nim`) and cleanup lowering (`src/ir/lower.nim`) | Typed storage/effects, cleanup control-flow, Defer fallback blocks, Try/Catch, Region/Allocate | Preserve existing cleanup edges; remaining Defer registrations guarded and reverse ordered. Temporaries are function allocations. Illegal escapes remain frontend errors. |
| Structured issue locations/trails | SourceSpan.file/start/end, Trace.trace/span, Try/failable values | Every emitted instruction retains offsets; Trace crosses a bounded nonallocating runtime trail adapter without replacing issue identity. |
| Equality/order and codecs | Compare of typed values; specialized runtime.codec externs | Scalar LLVM comparison, descriptor-specific recursive aggregate runtime comparison; existing codec runtime generated against asserted layouts. Padding is never compared/serialized. |
| File-scope constants (`src/ir/valid.nim`, `src/types/coerce.nim`) | Storage.value | Reuse the frontend's exact decimal range proof for 1–128-bit initializers. Relocation-bearing text and present/null optional constants receive explicit physical storage and padding. |

The qualified target remains Windows x64 from Batch 1. This batch does not claim new sysroots/platforms. Runtime C is restricted to support/adapters; FOO functions and control flow are emitted as LLVM IR. Foreign exports/native blocks, GPU/SIMD authoring, target startup/interrupt and instrumentation remain separately diagnosed until their planned batches.

Current frontend limitations must not be disguised as missing backend parsing: `src/ir/kind.nim` has no shift instruction; machine/library operations use runtime.arch calls. Compile-time `src/ir/eval.nim` currently accepts only fixed 8/16/32/64-bit scalars, addresses, slices and C records for layout; it rejects odd-width and 128-bit compile-time layout queries before backend lowering. These restrictions are shared by all backends.

Differential command (Windows, Nim 2.2.12, Clang/LLD and managed Zig 0.16.0):

```
nim c -r --cc:clang --mm:refc --path:. --nimcache:.artifacts/llvm-core/nimcache-refc --out:.artifacts/llvm-core/core.exe test/backend/llvm/core.nim
```

`test/backend/llvm/fixtures/cases.json` is the retained manifest; `core.nim` compiles each source independently through the shared frontend for c, zig and llvm in dev/release. It records output bytes, exit statuses and errors in `.artifacts/llvm-core/results.json`. Unsupported cases must have a checked backend-specific reason; missing tools and unexpected failures fail acceptance.

Complete gate from the repository root:

```powershell
./test/backend/llvm/acceptance.ps1
```

The script runs 16 prerequisite checks followed by the full source matrix. Its
`acceptance.json` remains failed until every check completes successfully.
`core/report.json` requires all three backends, both modes and exactly 252
observations from the 42-case manifest. `typed-ir/report.json` requires 24
observations and two explicit ABI rejection checks. A filtered run cannot satisfy
acceptance. `FOO_LLVM_CASE` is rejected by the complete script; `FOO_LLVM_ROOT` and
`FOO_LLVM_IRROOT` only select artifact directories for focused runners.

| Coverage | Retained fixtures/checks |
| --- | --- |
| Definitions/calls/entry/locals/branches/loops/merges | `control.iv`, `functions.iv`, `entry-value.iv`, `entry-error.iv`; `ircore.nim` cyclic simultaneous phi assignments and typed block arguments |
| Every signed/unsigned width 1–128 | Eight `integers-FIRST-LAST.iv` partitions: min/max, unsigned max, runtime add/subtract/multiply/divide, exact sign/zero extension to 128; reproducible `generate-integers.py`. Signed width one has no positive one divisor. |
| Checked failure behavior | `overflow.iv`, `unsigned-overflow.iv`, `subtract-overflow.iv`, `multiply-overflow.iv`, `divide-overflow.iv`, `division.iv`, `index-error.iv`; `wide.iv` includes signed-minimum remainder by negative one |
| Decimal32/64 conversion/arithmetic/comparison | `decimals.iv`: retained runtime calls, widening, integer conversion, NaN inequality/unordered comparison, infinity and signed zero; `values.iv` |
| Text/bytes/bools/optional/choice/records/sequences/pointers/unit | `values.iv`, `nested.iv`, `storage.iv`, `packed.iv`, `sequences.iv`, `pointers.iv`, `units.iv`; fixed arrays and three overlapping union fields in `ircore.nim` |
| Layout/reflection/alignment | `values.iv` aligned C record, size/alignment/field offsets/names/count compile-time assertions; `storage.iv` runtime width9/128 size/alignment; `pointers.iv`; `ircore.nim` fixed array indexing/length and union offsets; runtime C static assertions |
| Generic functions/types and reachability | `control.iv`, `nested.iv`, `functions.iv`, specialized library calls; existing `test/ir/{monomorph,reach}.nim` |
| Recursive equality/order and JSON bytes | `values.iv`, `nested.iv`, `decimals.iv`, `sequences.iv`, `codecs.iv`, `codec-errors.iv`, `serialized-values.iv`, `codec-functions.iv`; codec record callbacks and first-class runtime encoder |
| Borrow/move/releasing parameters/temp lifetime/cleanup | `sequences.iv`, `arena.iv`, `pointers.iv`, `cleanup.iv`, `exits.iv`, `entry-error.iv` entry failure cleanup; rejected owner-use/undeclared borrow in `released-error.iv`/`borrow-error.iv`; existing `test/types/{borrow,escape}.nim` |
| Error identity/trails and source provenance | `issues.iv`, `entry-error.iv`, checked-error fixtures; every successful LLVM build compares `source.json` with the original shared IR spans/traces, including fallback blocks |
| Invalid source/coercion/layout | `narrow-error.iv`, `uninitialized-error.iv`, `layout-limit.iv`, `runtime-codec-reference-error.iv`; errors must originate in the frontend on all three backends |

The exact prerequisite scripts are `test/types/{coerce,checker,layout,borrow,
escape,exhaust}.nim`, `test/ir/{valid,lower,eval,monomorph,reach}.nim`,
`test/backend/{c,zig}/emitter.nim`, and
`test/backend/llvm/{slice,optimization,ircore}.nim`. All original backend tests
and fixtures remain in the tree. The slice also verifies the project cache.
Compiler executable content participates in the project cache identity; LLVM
tool identities, effective target data layout and semantic policy remain in it.

Restrictions are exercised, not silently skipped:

| Specific test | Restriction and required work |
| --- | --- |
| `packed.iv` C dev/release | Legacy C rejects nested packed fields with `C packed fields must be integers or booleans`; Zig and LLVM execute the fixture. |
| `entry-value.iv` Zig dev/release | Legacy Zig declares hosted `main` as `anyerror!void` and rejects an integer return. C/LLVM preserve the established hosted discard-value/zero-exit contract. |
| `units.iv` C dev/release | Legacy C emits a void function parameter (`argument may not have 'void' type`); Zig/LLVM execute unit parameters and present/null optional unit values. |
| `ircore.nim` block parameters | Both legacy emitters fail with their concrete undeclared parameter diagnostic; LLVM executes typed block arguments. All three execute cyclic phi merges. |
| `layout-limit.iv` all backends | Frontend compile-time evaluator rejects integer128 layout. This does not restrict runtime LLVM layout. Extending it requires shared frontend/target evaluation work. |
| `runtime-codec-reference-error.iv` all backends | The existing frontend rejects the direct runtime reference as a codec record field with a function-type mismatch; FOO wrapper functions in `codec-functions.iv` work. The backend does not override the checker. |
| `test/ir/kind.nim`, `test/native/arch.c` | There is no source/IR scalar shift operator to port. Existing machine bit operations use `lib/arch.iv` and native runtime contracts, requiring the later architecture gate. LLVM's internal constant shift for a minimum value has a provably valid shift count. |
| `ircore.nim` foreign entry/callback rejection; `slice.nim` native rejection | Raw foreign ABI attributes and aggregate/wide native callbacks require an ABI classifier/thunks. Native code/assembly is explicitly rejected with source offsets. These are later ABI/platform gates. |
| `ircore.nim` packed codec rejection | The shared C codec runtime rejects `PackedStruct`; LLVM diagnoses the same restriction. Supporting packed JSON through the runtime boundary needs packed descriptors/marshaling rather than passing byte-packed FOO storage as a native C record. Direct packed construction/extraction/equality/order is qualified by `packed.iv`; packed JSON remains unqualified. |
| `specs/migration.md` target matrix and existing platform runners | Linux/macOS/ARM/WASI/threaded WASI/freestanding, startup/interrupt, GPU/SPIR-V/Vulkan, raw SIMD, runtime-free/custom linker/shared library builds and instrumented builds remain unqualified. They need runtime/linker/sysroot/ABI/device work, not a host-only core emitter. |

Successful executions compare exact output bytes and exit status across all
supporting backends. C/LLVM checked errors also require identical raw bytes and
exit status. Zig's existing native panics have different exits and nondeterministic
thread/address diagnostics; the manifest requires their established error kind
and exit, retains the complete raw bytes, and explicitly records this difference.
Frontend rejections and legacy compile failures count as checked observations,
not successful executable tests. No unsupported LLVM core case is hidden behind
a backend-specific manifest exception.

The gate scans generated FOO LLVM IR for unproven `nsw`, `nuw`, `noalias`,
`nonnull`, `range`, fast math and `inbounds` promises. Conservative load/store
alignment is one; owned allocations use their measured alignment. The existing
shared scalar purity proof is the only source of `memory(none)`, with runtime
and aggregate operations excluded. The qualified version policy remains the
one in `migration.md`: LLVM/LLD 18.1.3, Nim 2.2.12 and managed Zig 0.16.0 are the
tested host configuration; additional versions/targets require qualification.

Qualification run on 2026-10-11 in the main Windows x64 workspace: all 17
script checks passed, including the full 252-observation matrix and 24 typed IR
observations. The source matrix contains 210 executions (C 68, Zig 70, LLVM 72),
36 expected shared frontend rejections and six checked legacy compile
restrictions. The typed IR matrix contains 20 executions and four checked
legacy block-parameter restrictions. All source-map and emitted-assumption
checks passed. A fresh compiler also passed 42 focused observations after the
workspace dependency/build-driver edits and six failed-entry cleanup observations.
Retained evidence is `.artifacts/llvm-acceptance-final/{acceptance,evidence}.json`;
complete raw bytes and diagnostics remain under its `core/` and `typed-ir/`.
The manifest SHA1 is `59FC76681FAD4771919B42C59F92E06BFC36A025`. These results
qualify the documented fixture coverage; the explicit runtime/ABI/platform
restrictions above remain in force.
