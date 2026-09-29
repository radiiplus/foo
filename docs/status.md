# FOO v1 Feature Contract: What’s In and What’s Out

This page answers a practical question: **Which familiar language features exist in FOO v1, and which should you *not* assume exist just because you've used another language?**

---

## 1. Core Language

### ✅ What is in FOO v1
*   **Variables:** `constant` is strictly immutable (cannot be changed). `dynamic` changes via `set`. Local types are inferred (worked out by the compiler) unless explicitly annotated.
*   **Scope:** Lexical scoping (visibility based on written code blocks) with inner-block shadowing (an inner name temporarily hides an outer one). No duplicate names allowed within the same scope.
*   **Functions:** Positional and named arguments, defaults, final variadic parameters (one parameter accepts several arguments), overload sets (several parameter forms sharing a name), generics (code that works with several types), constraints, function values, scoped captured closures (local functions that remember nearby values), guards, and recursion (a function calling itself; requires an explicit result type).
*   **Control Flow:** `when`/`otherwise`, `while`, `for each`, exhaustive `match` (every possible case is covered), `stop`, `skip`, and early `give`.
*   **Types:** Aliases, records, packed records, choices, opaque types (internal details hidden), `optional T` with `null`, `failable T`, named record construction, structural record destructuring, and checked numeric rules. `nothing` remains the unit value and is not optional absence.
*   **Generics:** Square-bracket type parameters constrained by `Equatable`, `Hash`, `Ord`, or `Allocator`.
*   **Conversion:** Lossless conversions are narrowly defined. Other conversions require explicit library calls. **There is no cast operator.**

### ❌ What is NOT in FOO v1 (Do not assume these exist)
*   Escaping or heap-owned captured closures.
*   Return-type-only overload selection.
*   Partial application and function-composition expressions.
*   Conditional expressions (e.g., ternary operators).
*   Guaranteed tail calls.

---

## 2. Data and Memory

### ✅ What is in FOO v1
*   **Collections:** Typed modules for sequences, maps, sets, queues, stacks, and mutable text-keyed tables. *(Note: No collection literal syntax).*
*   **Transformations:** `map`, `filter`, `sort`, `find`, `dedup`, `reverse`, `take`, `drop`, `any`, `all`, `fold`, iteration, and checked `at` indexing. *(Note: No operator overloading).*
*   **Reusable patterns:** `Codec[T]`, `Machine[S, E]`, `Cursor[T, S]`, `Participant`, typed monotonic and calendar time, dimensional quantities, application contracts, generated property checks, and explicit pointer identity are standard-library APIs rather than new syntax.
*   **Ownership:** Scope arenas (groups of temporary memory released together), explicit `Allocator` values, tracked borrowed views, move/retention checks, and `after` cleanup blocks.
*   **References:** Non-null `pointer to T`. Nullability is handled via `optional pointer to T`. Raw address manipulation requires unsafe/native access.
*   **Safety:** Checked indexing/arithmetic, provenance-aware pointers (addresses whose origin is tracked), scope escape checks, and strict synchronization (worker coordination) rules. **Panics are fatal** (not recoverable with `fallback`).

### ❌ What is NOT in FOO v1 (Do not assume these exist)
*   Source-level lifetime annotations (written rules for how long data remains valid).
*   User-defined Copy/Drop traits.
*   Built-in reference counting or weak references.
*   A tracing Garbage Collector (GC).

---

## 3. Errors, Matching, and Metaprogramming

### ✅ What is in FOO v1
*   **Recoverable Errors:** Handled via `failable T`, `fail(error)`, postfix `try`, and expression-level `fallback`.
*   **Cleanup:** `after` runs on ordinary exits; `after error` runs while a failure is propagating.
*   **Pattern Matching:** Supports choice payloads, constants, literals, guards, `anything`, unreachable-arm checks, and strict exhaustiveness checks (proof that every case is covered).
*   **Compile-Time:** `eval`, immutable `reflect[T]`, and `embed("path")` run or inspect work while the program is being built.

### ❌ What is NOT in FOO v1 (Do not assume these exist)
*   Exception-based error handling.
*   Custom pattern protocols.
*   Macros or a user-defined annotation system.

---

## 4. Concurrency and Interoperability

### ✅ What is in FOO v1
*   **Concurrency:** Library-based overlapping work through scoped tasks, pools, channels, OS threads, mutexes (single-worker locks), condition variables, and atomics (shared operations completed as one step).
*   **C ABI:** The binary rules used to call C: `extern "C"`, C-layout records, callbacks, generated header bindings, dynamic libraries, and verified native contracts.
*   **Other Languages:** Rust and other libraries are accessed via the stable C ABI.
*   **Low-Level Access:** Typed surfaces for advanced HTTP, sockets, binary-safe files, durable file publication, JSON, allocators, atomics, OS, native C, and assembly.

### ❌ What is NOT in FOO v1 (Do not assume these exist)
*   `async` or `await` keywords.
*   Source-level `spawn` keywords.
*   Direct Rust ABI declarations (must go through C ABI).
*   *Note on Async:* Functions maintain a single type; the library operations choose the executor.

---

## 5. Modules, Builds, Packages, and Tools

### ✅ What is in FOO v1
*   **Modules:** One namespace per `.iv` file. Private-by-default, explicit `public` exports, aliases, explicit unaliased `public use` re-exports, and cycle detection.
*   **Builds:** C and Zig backends, dev/release optimization, target/CPU selection, products, resources, native inputs, and shared/project caches. `--explain` reports selected runtime substrates and their reasons.
*   **Current Optimization:** Concrete generic specialization, local pure-expression reuse, dead pure-result removal, release inlining and private-function sharing, measured byte-transfer paths, and single-allocation collection transforms.
*   **Packages:** Registry, Git, URL, and path dependencies. Semver (major/minor/patch version rules) constraints, deterministic `foo.lock` (the same inputs produce the same file), and platform/dev/optional dependencies.
*   **Entries:** One explicit default `entry`, plus simple named `entries` selected via CLI (`foo run NAME`).
*   **Tests:** File-level test blocks, filtering, watch mode, backend choice, native fixtures, timeouts, and the `testing` assertions module.
*   **Benchmarks:** Executable files under `benchmark/`, warmups, repeated samples, min/median/mean summaries, backend choice, and JSON events.
*   **Tooling:** Formatter, LSP (the editor communication protocol), graph/IR inspection (viewing the compiler's simplified program form), C binding generation, staged operation output, grouped colored diagnostics, and JSON output.

### ⚠️ What is NOT STABLE yet (Use with caution)
*   Source feature flags.
*   Private registries.
*   Microbenchmark declarations.
*   Test mocks.
*   A public coverage CLI.
*   Effectful or loop pipeline fusion, cross-block/shared allocation placement,
    suspended continuation frames, Apple/BSD and Zig event reactors, adaptive
    search indexing, and typed codecs for arbitrary sequence/choice/pointer
    graphs. The current optimizer covers local pure pipelines, local stack-slot
    elimination, synchronous continuation removal, typed record codecs, PGO
    (profile-guided optimization using earlier run measurements),
    C task pools on Windows/Linux, and adaptive file/text paths.

---

### 📌 Final Note on Specifications
The detailed language contract lives in the versioned specifications under the `specs/` directory. This book teaches that same contract using examples. **If a feature is listed as absent in this document, do not write code that depends on an undocumented spelling or workaround for it.**
