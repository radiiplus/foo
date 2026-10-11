# LLVM backend — Batch 1

The LLVM backend consumes the compiler's shared typed IR directly. It emits
structured textual LLVM IR; it does not generate C or Zig. The existing backends
are retained. No compatible LLVM binding is already used by this Nim project,
so this initial slice uses the installed Clang LLVM pass manager and LLD.

## Prerequisites and verified target

Verified configuration: Windows x64, LLVM **18.1.3**, target triple
`x86_64-pc-windows-msvc`, with `clang.exe` and `lld-link.exe` from the LLVM
distribution on PATH. Install Visual Studio Build Tools' Desktop development
with C++ workload, including the MSVC x64 runtime libraries and Windows SDK,
for Clang's hosted executable link. Compiler/test builds use Nim **2.2.12**
and Clang; the Node launcher requires Node **22.13+**.

Set `FOO_LLVM_CLANG` to an explicit Clang executable, or set the project's
`build.compiler`. LLD must be installed beside that executable. Other host
triples and cross targets are rejected; this batch does not establish Linux,
macOS, ARM, WebAssembly or freestanding support.

## Developer commands and retained diagnostics

From the repository root, build the compiler and run the focused execution gate:

```powershell
node tools/native.mjs
nim c -r --cc:clang --path:. --nimcache:.artifacts/llvm-test-cache --out:.artifacts/llvm-test.exe test/backend/llvm/slice.nim
```

With the built `foo.exe`, select LLVM explicitly (the fixture also selects it
in its manifest):

```powershell
cd test/backend/llvm/program
../../../../.artifacts/native/foo.exe build main.iv --backend llvm --target windows-x64
./output/app.exe
$LASTEXITCODE # 42
```

Every LLVM build saves `main.ll`, `verified.ll`, `main.obj`, `llvm.json`,
`source.json`, and `verify/compile/link.command` plus matching `.diagnostics`
files in the project's `.artifacts/build` directory. The focused test retains
these under `.artifacts/llvm-slice-local` (isolated names in the native suite).
This always-on developer artifact mode also preserves failure diagnostics.

Clang runs `-x ir -S -emit-llvm -Xclang -llvm-verify-each` as a mandatory
verification stage before object generation, then compiles LLVM IR directly
and links the object with `-fuse-ld=lld`. Dev uses O0; release uses O2. Diagnostics
and the project cache identity include Clang version, target triple, data
layout, optimization level, generic CPU feature policy, verifier flag, and LLD
version. An LLVM IR probe queries Clang's effective triple (including detected
MSVC ABI version) and data layout before the project cache lookup.
Unsupported instructions report source file and byte offset where the shared
IR supplies them; function diagnostics also retain the available source line.

## Supported slice and next work

Parameterless integer/void entry functions, integer widths 8/16/32/64, stack
slots, loads/stores, and add/subtract/multiply are implemented. Checked integer
arithmetic uses LLVM overflow intrinsics and traps on overflow. The entry
wrapper returns the integer result as the OS exit status (void returns zero).
The focused test proves 19 + 23 returns 42 at O0 and O2, checks LLVM-specific IR
and object artifacts, and checks rejection of invalid/unsupported IR.

Next unsupported constructs: general control flow
and phi nodes, division/remainder, comparisons and conversions, floating point,
text/sequences/records, globals, generics requiring additional lowering,
allocation/cleanup, failable results, runtime services, native interop, vectors,
threads/GPU, libraries and custom linking or instrumentation. Overflow failures
currently trap without the old backends' rich runtime panic messages. General
debug information is not implemented. Unsupported constructs fail explicitly.

## Batch 3: evidence-gated optimization and semantic metadata

The LLVM path consumes the same semantic optimizer as C/Zig. Release mode
(or development `build.semantic`) applies its existing purity, type-equivalence,
escape, identity, and architecture cost checks before emission. Within the
supported scalar slice, stack promotion, identity conversion elimination,
private equivalent-function sharing, and cost-budgeted pure-call inlining
are therefore explicit FOO decisions. Scalar integer parameters and direct default-ABI
calls are lowered, including calls that failed the inlining proof.

Retained functions use `noinline`: LLVM does not replace FOO's boundary budget.
Only the shared private-function purity proof enables `memory(none)`. Public,
attributed, checked, or effectful functions do not gain
extra purity promises from spelling or types. No `noalias`, `nonnull`, overflow
flags, or fast-math flags are invented. Loads/stores use conservative alignment
one because pointer types do not prove address alignment. Volatile memory
accesses retain LLVM `volatile` and cannot undergo shared slot promotion.
Same-type conversion elimination also requires absence of effects/failures.
Checked overflow remains an intrinsic and branch, even with an unused result.

LLVM automatic loop/SLP vectorization is disabled. The existing runtime SIMD
candidate remains restricted to C/Zig; LLVM uses its scalar fallback until
backend parity and representative performance evidence exist. Other unsupported
IR still fails explicitly; runtime serialization/continuation specialization
is not claimed as executable LLVM support. No speedup is claimed for this batch.

`llvm.json` records the versioned semantic policy and shared optimizer counters;
`--explain` reports the shared proofs, retained boundaries and scalar fallback.
Counters describe the shared pass before reachability, not final machine-code
instruction counts. The policy and vectorization setting participate in the
LLVM cache identity alongside target/tool versions. O0/O2 verification and
linking use identical vectorization settings.

Optimization and Internal Implementation Review: the observable contract is
unchanged values, failures, volatile accesses, and protected function identity.
Candidates reuse the shared semantic passes rather than introducing a second
optimizer. Failed proofs retain calls/storage or reject unsupported lowering.
Parity covers retained and eliminated calls at O0/O2, volatile loads/stores,
public/noinline rejection, observable conversion guards, and unused overflowing
arithmetic. Run `test/backend/llvm/optimization.nim` with the same Nim command
as the slice gate. Performance specialization remains unqualified pending
representative target measurements; C/Zig slot/conversion guards were also
re-evaluated because LLVM exposed missing observable-access checks.
