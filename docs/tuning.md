# Optimization Under the Hood

FOO treats optimization as a semantic substitution problem (replacing an
operation while preserving what the program means). An operation has
one public meaning, but it may have several internal implementations. The
compiler selects a compatible path from the target, CPU profile, build mode,
capability level, data shape, and information already known at compile time
(while the program is being built rather than while it runs).

The first goal is to remove work. Faster instructions matter only after the
compiler has considered eliminating repeated computation, allocations
(requests for memory), copies,
branches, and operating-system transitions.

## The substitution rule

For each operation, FOO compares a native implementation with the relevant
runtime, libc (the standard C system library), operating-system, or
conventional algorithm. A FOO-native path
is eligible only when it preserves all observable behavior and has performance
evidence for the workload where it is selected.

The required order is:

1. Eliminate unnecessary work.
2. Reuse an already computed value.
3. Avoid allocation or copying.
4. Batch adjacent work.
5. Select a better data structure or algorithm.
6. Specialize from compile-time type, size, and target information.
7. Use architecture instructions when they improve the measured workload.
8. Retain the external or portable implementation when it is better.

An internal path is not preferred merely because it belongs to FOO. Kernel
services (privileged operations supplied by the operating system) remain
necessary for files, virtual memory (address space managed by the operating
system), sockets, timers, process
control, and hardware-backed security. Mature system libraries also remain the
right fallback when they are faster, safer, or more portable.

## Execution specialization

Execution specialization gives these decisions one common model. The source
operation keeps one meaning, while the compiler considers what it knows at
three levels:

| Knowledge | Examples | Possible benefit |
| --- | --- | --- |
| Build time | Exact type, constant size, lifetime, effects, destination | Remove a selector, temporary, allocation, copy, or entire unused operation. |
| Run time | Actual size, overlap, readiness, contention (workers competing for one resource) | Choose a measured path when the answer was not known during the build. |
| Target | CPU profile, operating system, ABI (binary rules between compiled components), installed capability | Use compatible instructions or an OS service without probing the build computer. |

The most important question is not "How can this call be faster?" It is "Does
this call or its surrounding abstraction need to exist in the generated
program?" If a result, effect, and failure are all provably unobservable (unable
to change anything the program's user can detect), the
work can disappear. If only the implementation can change, FOO selects among
compatible paths and retains a fallback.

Postfix `try` is a current example. Recoverable errors remain typed values. The
C backend tests the failure field, performs required cleanup, and returns the
same error; the Zig backend uses its ordinary error-union control flow. FOO does
not require a separate exception runtime (machinery for throwing and catching
exceptions) for propagation.

Generic specialization and adaptive byte transfer are also current instances
of this principle. The compiler now applies the same selection model to local
boundary and allocation elimination, synchronous continuation removal, typed
record codecs, profile-guided inlining, hosted C task pools, exact-size file
reads, and adaptive text search. Suspended continuations, general storage
placement, effectful fusion, user-space scheduling, and workload-selected
queues remain design work.

## Boundary elimination

A boundary is a point where a program normally changes representation or hands
work to another layer. Common boundaries include function calls, allocations,
copies, library adapters, serialization buffers, schedulers, threads, runtime
services, and kernel calls.

FOO reviews each boundary, but it does not assume that removing a boundary is
always beneficial. A kernel boundary remains necessary for privileged or
globally coordinated work such as sockets and virtual memory. A library
boundary remains useful when its implementation is already the safest or
fastest path.

Consider a value that must be encoded and written. A conventional path may
construct an encoded temporary buffer and then copy it into a network buffer.
FOO may eventually encode directly into the destination when the destination,
capacity, codec, and failure behavior are known. It may not dump the value's
memory layout onto the wire: memory padding, byte order, validation, and format
versions belong to the wire contract.

## Operation fusion

A chain such as:

```text
input through parse then validate then transform then save
```

may create an intermediate value after every stage. A fusion pass can remove
some of those values, calls, allocations, and copies when one combined path has
exactly the same behavior.

Fusion must preserve evaluation and I/O order, checked failures, `fallback`,
error traces, `after` cleanup, ownership, aliasing (several names referring to
the same storage), cancellation, fairness (ensuring work is not indefinitely
ignored), backpressure (slowing producers when consumers cannot keep up),
iteration order, atomics, foreign calls, public ABI, and wire
formats. It cannot delay an error, combine visible writes, silently make an
eager collection lazy, or skip validation. FOO currently performs local
pure-expression reuse and fuses adjacent private pure calls by inlining the
chain and removing its call boundaries. General effectful, looping, or
cross-block pipeline fusion remains design work.

## Storage and suspension choices

An allocation review begins by asking whether storage is required. The current
local pass removes non-escaping stack slots in one basic block by forwarding
their stored values directly to loads. Depending on proven lifetime and sharing,
broader selection may use a compile-time value, the stack, a region, persistent
storage, or shared storage. Existing regions and bulk cleanup provide an
important foundation, but the compiler does not claim general cross-block,
escaping, or shared allocation placement.

Suspending work has a similar decision tree. A proven synchronous `task.block`
callback is currently rewritten to a direct call and needs no suspension
machinery. A genuinely suspending continuation (saved work that resumes later)
might use a state machine (stored states and allowed transitions), a larger one
might use a specialized frame (storage holding paused local values), and a
long-lived task might require
allocated storage. Those suspending variants remain design candidates.

## Current compiler work

Generic functions and records are specialized (turned into versions for exact
types) before backend emission (code generation). This removes runtime generic
dispatch (choosing a type-specific operation while the program runs) and gives
the backend exact layouts and element widths. The semantic optimizer also
shares repeated pure expressions (calculations with no outside effects) within
a basic block (one straight-line section of code) and removes unused pure
results. Release builds also share equivalent private pure functions and inline
(place directly at the call site) small private
pure functions within a target-weighted per-caller budget. Public and
address-taken functions retain their identity. Checked integer arithmetic,
failure propagation, cleanup, volatile access (reads and writes that must
happen exactly as written), and atomic operations (shared operations completed
as one indivisible step) are never
classified as freely removable work.

This distinction preserves important behavior. For example, an unused checked
addition can still overflow, so removing it would change the program. A repeated
decimal expression without effects can be reused when its inputs are identical.

## Implementation audit

| Optimization | Status | Applied behavior |
| --- | --- | --- |
| Generic specialization | Current | Concrete function and record types are emitted before backend lowering. |
| Pure-expression reuse and dead-result removal | Current | Basic-block reuse uses exact typed keys; only total effect-free results are removed. |
| Private-function sharing and inlining | Current in release | Equivalent private pure functions share one body; small calls use the selected CPU cost profile and caller budget. |
| Adaptive byte transfer | Current | C and Zig select overlap-safe portable or target-specific paths by target, CPU, mode, size, and capability. |
| Sequence transform allocation | Current | Public `sized` construction and `map` reserve exactly; `filter` and `dedup` reserve then compact once. Persistent flat `append` preserves prior values and therefore allocates and copies. |
| Mutable table representation | Current | Text-keyed tables use contiguous open addressing on both backends. |
| Atomic lowering | Current | Operations retain their requested valid memory ordering. |
| Artifact (generated build output) cache identity | Current | Project inputs, compiler executable, backend, target, CPU/native options, optimization mode, and semantic mode are hashed. |
| Strategy explanations | Current | `--explain` reports selected runtime implementations and reasons. |
| Typed failure propagation | Current | Postfix `try` lowers to ordinary backend success/failure control flow with cleanup. |
| Execution-specialization engine | Current | One evidence-gated selector enforces backend, target, CPU, mode, size, overlap, contract, and fallback constraints. |
| Boundary elimination and pipeline fusion | Current, local | Redundant same-type conversions disappear; adjacent private pure calls inline as one boundary-free chain. General loop and effectful fusion remains design work. |
| Automatic allocation placement | Current, local | Non-escaping block-local stack slots are forwarded and removed. Cross-block, shared, and escaping placement remains explicit. |
| Continuation specialization | Current, synchronous | A proven synchronous `task.block` callback becomes a direct call. Suspending continuation frames remain design work. |
| Direct serialization and generated parsing | Current | Constant JSON quoting folds at compile time; `codec.encode[T]` and `codec.decode[T]` generate concrete record/scalar code on C and Zig, and the completed output buffer is adopted without a second full copy. |
| Event-backed task pool | Current on hosted C | C pools dispatch through IOCP on Windows and epoll/eventfd on Linux. Zig and other targets retain the threaded fallback; network readiness integration remains design work. |
| PGO (profile-guided optimization using earlier run data) | Current | Versioned coverage profiles enlarge inlining thresholds and budgets for measured hot functions and participate in cache identity. |
| Adaptive file and text search paths | Current on hosted runtime | Seekable files (files whose position can be moved) use exact-size direct ownership; unknown sizes stream geometrically. Text search selects single-byte, small linear, or large skip-table search. |

## Adaptive byte transfer

`memory.transfer` and the runtime's internal copies preserve `memmove` overlap
semantics on every path. The current C release paths are:

| Conditions | Selected path | Technical behavior |
| --- | --- | --- |
| x86-64 with AVX2, 128 through 256 bytes | AVX2 | Eight unaligned 32-byte head/tail loads occur before stores, so overlap remains correct. |
| x86-64 machine capability, 1 KiB through 8 KiB, no overlap | `rep movsb` | The processor performs the bulk transfer; overlapping or differently sized ranges use `memmove`. |
| AArch64 release | compiler intrinsic | The compiler lowers overlap-safe transfer for the selected target. |
| Other C targets and sizes | portable `memmove` | The system implementation handles size and microarchitecture details. |

The Zig runtime uses overlap-safe forward or backward copying. Release builds
use 32-byte blocks for an AVX2 x86-64 target and 16-byte blocks for AArch64;
other builds use the target word size. Zero-length and identical-address copies
return without touching memory.

The benefit is not simply wider instructions. Small copies avoid a path intended
for bulk data, overlapping copies stay correct, and large transfers return to
the system implementation where cache, streaming, and platform tuning can be
more effective.

## Collections and representation

Typed sequences use contiguous element storage (items stored next to one
another) rather than one allocation per
element. `sequence.map` reserves its exact result once. `filter` and
`deduplicate` reserve once and compact once, which removes repeated allocation
and copying while preserving element order. Deduplication still performs
quadratic equality comparisons (the work can grow with the square of the item
count), so a hash-based algorithm remains future work
for hashable types and large inputs.

The mutable `table` uses open addressing (storing entries directly in the hash
table) for text keys. Keeping entries in one table improves locality (keeping
related data close in memory) and avoids a separate allocation for each node. The
immutable `map` retains insertion order and value semantics; FOO does not
silently exchange those semantics for the table implementation.

## Tasks and operating-system services

The hosted C task pool uses IOCP on Windows and epoll with `eventfd` on Linux.
Pool submissions wake a bounded worker set through the selected event queue;
`task.wait` observes completion of every submitted callback. Scoped tasks still
use native threads, and Zig, Apple/BSD, and unsupported targets report the
threaded fallback. Connecting sockets and suspended continuation frames to the
same event queues remains design work.

Atomics lower to C11 operations with the requested memory order. A weaker order
is never substituted merely because it might be faster. HTTP on Windows uses
WinHTTP and the operating-system certificate store, avoiding an OpenSSL runtime
dependency while retaining platform trust and networking facilities.

## Build and cache specialization

The selected target, CPU, backend, optimization mode, compiler contents, and
project inputs participate in cache identities. Reusing an artifact (generated
build output) therefore
cannot accidentally reuse instructions for a different CPU promise. Generic
specializations are generated from concrete types, while target profiles make
instruction features available to native lowering.

`foo build --explain` and `foo run --explain` show the operation, substrate,
implementation, and reason selected for runtime paths used by the program. A
typical explanation may identify an overlap-safe copy path, a single-allocation
sequence transform, open-addressed table storage, or the reported task strategy.

## Benchmark discipline

Every threshold and specialized path must be compared with its portable
alternative using `foo benchmark`. Evidence should cover tiny, medium, and
large inputs; aligned and unaligned storage; overlap where permitted; warm and
cold data; successful and failing cases; and each supported architecture.

Benchmarks do not replace correctness tests. A candidate path must first pass
the same contract suite as the portable implementation. Measurements report
the hardware, target, compiler mode, sample count, and input distribution.
Regressions outside the winning range keep the portable path or change the
selection threshold.

## Required implementation review

Every foundational subsystem and substantial revision must include an
Optimization and Internal Implementation Review. The review answers:

1. What behavior, failures, cleanup, ordering, and ownership are observable?
2. Which calls, allocations, copies, conversions, and external boundaries exist?
3. What is known at build time, run time, and for the selected target?
4. Can work or a boundary disappear, can adjacent work fuse, or is a specialized
   FOO, OS-assisted, or portable path appropriate?
5. What compatibility predicate (the rule deciding whether a path may run) and fallback protect the choice?
6. Which parity cases (tests proving two paths behave the same) and representative benchmarks prove it?
7. What concise reason will `--explain` show?
8. Which older touched implementation was re-evaluated?

The correct result may be to retain the existing portable or operating-system
implementation. A candidate stays labeled **Design** until its implementation,
shared contract, parity coverage, fallback, benchmark evidence, and explanation
all exist.

## Semantic limits

Optimization may change layout of private temporary values, instruction order
where no dependency observes it, and the implementation behind a standard
operation. It may not change:

- failure identity or the point where a checked failure becomes observable;
- cleanup, I/O, volatile, or foreign-call order;
- atomic ordering and synchronization;
- public ABI (binary rules used when compiled code calls other compiled code),
  record layout, or function identity;
- byte-copy overlap behavior;
- collection ordering, ownership, or aliasing contracts (rules for multiple
  references to the same storage);
- deterministic results (the same input always gives the same output) promised
  by an API.

Automatic search indexing, fixed-size copy expansion, dimensional
representations, effectful or loop pipeline fusion, cross-block allocation
placement, suspended continuation frames, and socket-reactor integration remain
design work. Current specialization is deliberately limited to the evidenced
scopes listed in the implementation audit.

Next: [The Compiler](compiler.md).
