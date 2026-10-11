# LLVM core lowering contract

Batch 2 uses `src/build/compiler.nim` unchanged: parse/resolve/check, compile-time expansion, typed `src/ir/lower.nim`, specialization and semantic optimization. The driver validates that IR, applies existing reachability and `prepare`, then emits LLVM. No source syntax or typing rule is interpreted by the backend. Shared lowering now retains AST source spans, represents mutable projections consistently, and emits explicit wrapper coercions accepted by the existing checker and IR validator.

| Frontend/type representation | Typed IR | LLVM implementation |
| --- | --- | --- |
| Function signatures, specialized generic calls and callable types (`src/types/checker.nim`, `src/ir/monomorph.nim`) | Function.params/ret, Call.func/callee/args, Global function value | Direct internal LLVM calls, opaque function pointers; runtime calls use pointer adapters. |
| Mutable places, assignment, branch/loop lowering (`src/ir/lower.nim::lowerFunction`, nested `place`/`statements`) | Alloc slot, Load/Store, Jump/Cjump, Phi and block arguments | Entry-allocated typed storage, explicit edges; all merge sources read before destinations are written. |
| Integer signedness/width and permitted widening (`src/types/coerce.nim`) | Int/Uint 1–128, Add/Sub/Mul/Div/Remainder, Compare/Convert | Semantic-width overflow intrinsics and explicit panic branches; canonical extension to addressable 8/16/32/64/128-bit storage. No nsw/nuw, noalias, nonnull or range assumptions. |
| Decimals/booleans/bytes/characters/text | Float32/64, Bool, Uint8/32, constant Slice Uint8 | IEEE operations without fast math; byte bool at memory boundaries, i1 predicates; length-bearing UTF-8 text. |
| Records/optionals/choices/arrays/sequences/pointers (`src/ir/node.nim`) | Struct/ExternStruct, Optional, TaggedUnion, Array/Slice/Ptr; Construct/Extract/Index/Length | Target-sized storage/offsets from layout.nim; zeroed construction; checked indexing, active payload comparisons, pointer-only runtime marshaling. |
| Reflection and compile-time queries (`src/ir/eval.nim`) | Folded frontend constants, Reflect.typeArg | Folded queries remain frontend decisions; runtime reflection measures qualified target layout. C runtime asserts sizes, alignments and record offsets at compile time. |
| Borrow/move/release checking (`src/types/checker.nim`, `escape.nim`) and cleanup lowering (`src/ir/lower.nim`) | Typed storage/effects, cleanup control-flow, Defer fallback blocks, Try/Catch, Region/Allocate | Preserve existing cleanup edges; remaining Defer registrations guarded and reverse ordered. Temporaries are function allocations. Illegal escapes remain frontend errors. |
| Structured issue locations/trails | SourceSpan.file/start/end, Trace.trace/span, Try/failable values | Every emitted instruction retains offsets; Trace crosses a bounded nonallocating runtime trail adapter without replacing issue identity. |
| Equality/order and codecs | Compare of typed values; specialized runtime.codec externs | Scalar LLVM comparison, descriptor-specific recursive aggregate runtime comparison; existing codec runtime generated against asserted layouts. Padding is never compared/serialized. |

The qualified target remains Windows x64 from Batch 1. This batch does not claim new sysroots/platforms. Runtime C is restricted to support/adapters; FOO functions and control flow are emitted as LLVM IR. Foreign exports/native blocks, GPU/SIMD authoring, target startup/interrupt and instrumentation remain separately diagnosed until their planned batches.

Current frontend limitations must not be disguised as missing backend parsing: `src/ir/kind.nim` has no shift instruction; machine/library operations use runtime.arch calls. Compile-time `src/ir/eval.nim` currently accepts only fixed 8/16/32/64-bit scalars, addresses, slices and C records for layout; it rejects odd-width and 128-bit compile-time layout queries before backend lowering. These restrictions are shared by all backends.

Differential command (Windows, Nim 2.2.12, Clang/LLD and managed Zig 0.16.0):

```
nim c -r --cc:clang --mm:refc --path:. --nimcache:.artifacts/llvm-core/nimcache-refc --out:.artifacts/llvm-core/core.exe test/backend/llvm/core.nim
```

`test/backend/llvm/fixtures/cases.json` is the retained manifest; `core.nim` compiles each source independently through the shared frontend for c, zig and llvm in dev/release. It records output bytes, exit statuses and errors in `.artifacts/llvm-core/results.json`. Unsupported cases must have a checked backend-specific reason; missing tools and unexpected failures fail acceptance.
