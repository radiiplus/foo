# Optimization

Version: 1.

Optimization preserves FOO's observable behavior, including errors, arithmetic
checks, effect order, atomic ordering and overlapping memory copies. Source
spelling or visual similarity is not evidence of equivalence.

## Internal substitution

Every language, library, runtime, and toolchain operation is specified by its
semantics rather than by one implementation. Before depending on an operating
system facility, libc routine, runtime abstraction, or conventional algorithm,
an implementation must evaluate whether a FOO-native path can remove work or
perform the work more efficiently for a defined workload. It must also evaluate
whether the external facility is already the better implementation.

Selection follows this priority:

1. eliminate the operation when its result and effects are unnecessary;
2. reuse proven-equivalent work;
3. eliminate allocation, copying, branches, and system transitions;
4. batch compatible operations;
5. choose a better representation, data structure, or algorithm;
6. specialize from compile-time type, size, layout, and target information;
7. use compatible architecture instructions;
8. improve individual instructions after the larger costs are addressed.

No internal implementation receives preference solely because it is internal.
The operating system remains authoritative for facilities requiring privilege,
global coordination, device access, or kernel state. An established external
implementation remains eligible whenever it is faster, safer, smaller, or more
portable for the selected workload.

## Execution specialization

Execution specialization is the common architecture behind internal
substitution. A source operation has one semantic contract and may have several
implementations. Selection may use three kinds of knowledge:

- compile-time knowledge, including exact types, values, sizes, layouts,
  lifetimes, effects, destinations, targets, and CPU profiles;
- runtime knowledge, including actual size, overlap, contention, readiness,
  cache state proxies, and resource state;
- platform knowledge, including operating-system services, hardware features,
  calling conventions, and deployment capabilities.

When compile-time knowledge uniquely selects a path, the generated program
must not retain a runtime selector merely to preserve the abstraction. Runtime
dispatch is permitted when its cost is measured and its predicate cannot alter
the operation's meaning. Cross-compilation uses the declared target promise,
not accidental features of the build host.

Specialization first asks whether the abstraction or operation is needed at
all. It may erase an unused operation, a temporary representation, a redundant
conversion, a provably synchronous suspension point, or an intermediate buffer
only when every associated effect and failure is also unobservable. Making an
operation cheaper is secondary to proving that no operation is required.

Error propagation is ordinary typed control flow. A backend may lower postfix
`try` to a test and branch without an exception runtime, but it must preserve
the error value, trace, cleanup, and exact propagation boundary.

Executable emission uses whole-module reachability before backend generation.
The roots are the executable entry, startup and interrupt entries, and exported
ABI functions. Library products additionally root public functions. Direct
calls and address-taken function values extend the reachable set. Only storage,
external runtime declarations, native contracts, and traces referenced by that
set may be removed. When no executable or library root exists, emission keeps
the module intact rather than guessing an entry.

Runtime and service inclusion is derived from the reachable declarations, not
from every declaration made visible by an import. A backend may omit lifecycle
setup only when no retained operation requires its allocation or cleanup
contract. Link-time section collection is a final safeguard, not a substitute
for semantic reachability. Release stripping may remove symbols and debug
records, but it must preserve exported ABI symbols and requested debug mode.

Allocation placement is also a selection problem. Compile-time storage, stack
storage, region storage, persistent storage, or shared storage are eligible
only when lifetime, address identity, alignment, escape, cleanup, and task
sharing rules permit the substitution. FOO does not turn an escaping or shared
value into stack storage merely because stack allocation is faster.

The current implementation removes block-local non-escaping stack slots,
same-type conversions, adjacent private pure call boundaries, and proven
synchronous `task.block` callbacks. It generates the standard JSON encoding and
parser for concrete scalar, optional, sequence, choice, and record codecs and adopts the completed encoded
buffer without a second full-buffer copy. Suspending state machines,
specialized continuation frames, effectful loop fusion, and general storage
placement remain outside this implemented scope. An in-memory record layout is
not a wire format; direct serialization obeys the codec's field names, JSON
encoding, validation, and failure rules.

## Boundary elimination and fusion

The optimizer must inspect function, allocation, copy, representation, runtime,
library, serialization, scheduler, thread, operating-system, and kernel
boundaries. A boundary may be removed only if its complete observable contract
is preserved. Kernel entry cannot be removed when privilege, device access,
global coordination, or kernel-maintained state is required.

Adjacent operations may be fused into one implementation when their composed
contract is equivalent to executing them separately. Fusion analysis includes:

- value and representation compatibility between stages;
- effect, I/O, volatile, foreign-call, and atomic order;
- checked failures, fallback behavior, traces, and the point of failure;
- allocation failure, ownership transfer, aliasing, and cleanup;
- laziness, iteration order, cancellation, fairness, and backpressure;
- public ABI, wire format, and debugging or profiling observations promised by
  the selected mode.

Fusion may eliminate intermediate values, buffers, copies, calls, scheduler
transitions, or repeated validation. It may not silently turn a materialized
collection into a lazy one, combine externally visible writes, delay an error,
or bypass a codec or security check. A failed proof retains the unfused path.

## Selection contract

An adaptive operation may select from several implementations using only
inputs that participate in correctness and cache identity. These include target,
CPU profile, backend, optimization mode, capability level, value type, known
size, alignment, overlap, representation, contention, and platform support.
Dynamic dispatch may additionally inspect runtime size or state when the cost
of inspection is included in its measurements.

Every selected path must have:

- one documented semantic contract shared with its portable fallback;
- parity tests covering success, failure, boundaries, aliasing, and cleanup;
- an explicit compatibility predicate;
- benchmark evidence for the range in which it is selected;
- a portable or platform implementation outside that range;
- a stable explanation containing the operation, path, and selection reason.

Thresholds are target-specific performance policy, not source-language
semantics. They may change between compiler releases without changing a
program's result. A target feature is a deployment promise: generated code may
require the selected feature and need not probe the build host while
cross-compiling.

`foo build --explain` and `foo run --explain` report substrate decisions used by
the program. Explanations describe the selected mechanism and reason without
dumping backend commands or every compiler instruction.

## Evidence

A specialized path must be measured against the fallback over representative
input distributions. Relevant suites include tiny, medium, and large values;
aligned and unaligned storage; permitted overlap; warm and cold cache states;
successful and failing operations; realistic contention; and every architecture
where the path is enabled. Results record hardware, target, build mode, compiler
version, sample count, and workload.

A synthetic benchmark is evidence for its measured workload only. It cannot by
itself justify a universal path. Correctness parity precedes performance
measurement, and a regression outside the winning range requires a threshold,
fallback, or removal of the specialized path.

When a foundational change touches an existing subsystem, that subsystem must
be re-evaluated for work and representation that the new information can
eliminate. Validated components may be revised, but the revision repeats their
parity, benchmark, portability, and explanation requirements.

## Optimization and internal implementation review

Every foundational feature, subsystem, and substantial revision must include
an Optimization and Internal Implementation Review. The review records:

1. the semantic contract and observable behavior;
2. current calls, allocations, copies, representations, and external
   boundaries;
3. compile-time, runtime, target, and hardware knowledge available for
   selection;
4. eliminated-work, fused, specialized, FOO-native, OS-assisted, and portable
   candidate paths;
5. compatibility predicates, cache inputs, and the required fallback;
6. parity cases for success, failure, boundaries, aliasing, cleanup,
   concurrency, and deterministic behavior as applicable;
7. representative benchmark workloads and recorded evidence;
8. the stable `--explain` reason for each selected path; and
9. older touched implementations that were re-evaluated.

The review may conclude that the existing external or portable path is best.
If a candidate lacks an implementation, shared contract, parity suite,
fallback, benchmark evidence, or explanation, its status is Design and release
documentation must not describe it as applied behavior.

Release builds may share equivalent private functions, remove unused pure
computations and inline calls within a cost budget. The budget accounts for
operation cost and the selected architecture. Public and address-taken functions
retain their identity. Development builds may enable semantic optimization with
`build.semantic`; release builds enable it by default.
Costs are relative estimates, not cycle counts or measurements of a specific CPU.

`foo build -mcpu x86-64-v3` selects a CPU profile. The equivalent persistent
setting is `build.cpu` in `project.json`. A command-line choice overrides that
setting; otherwise the target preset supplies the CPU. The architecture must
match the selected target. These choices do not change FOO syntax.

| Profile | Relevant instruction support |
| --- | --- |
| x86-64 | SSE, SSE2 |
| x86-64-v2 | SSE through SSE4.2 |
| x86-64-v3 | AVX, AVX2, FMA |
| x86-64-v4 | AVX-512 F, BW, DQ, VL |
| arm64 | NEON |
| apple_m1 | Apple M1, NEON |
| arm64-sve | NEON, scalable vectors |
| rv64g | Integer, multiplication, atomic and floating-point operations |
| rv64gcv | RV64G with compressed instructions and scalable vectors |

`baseline` selects the architecture's baseline profile. A vector-capable target
allows vector instructions; it does not require every operation to use them.
Scalable vectors have no fixed width. The `linux-x64-v3` and `windows-x64-v3`
presets select v3; ordinary x64 presets retain baseline requirements.

Optimized copies choose an implementation using the target, CPU, capability
level, optimization mode and portable-substrate override. Every choice preserves
the same bounds and overlap behavior. Choosing a CPU is a deployment promise:
the executable is only required to run on processors supporting that profile.
Cross-compilation does not execute the selected instructions on the build host.

The C AVX2 path currently handles 128 through 256 bytes with eight 32-byte
head/tail loads completed before stores. The machine x86-64 path uses
`rep movsb` for non-overlapping copies from 1 KiB through 8 KiB. Other sizes,
overlap on the machine path, and unsupported targets use overlap-safe
`memmove`. The Zig path copies forward or backward in 32-byte AVX2, 16-byte
AArch64, or target-word blocks. These ranges are implementation policy and must
remain guarded by the shared overlap contract.

Sequence transforms reserve their result once and compact once. Mutable text
tables use open addressing. Hosted C task pools dispatch through IOCP on Windows
and epoll with `eventfd` on Linux; scoped tasks and other targets retain the
threaded fallback. Seekable file reads reserve from the measured size and adopt
the resulting buffer directly, while unknown sizes use geometric streaming.
Text search selects a single-byte, small linear, or large skip-table path.
Atomic operations retain their requested memory order. These substitutions do
not permit changes to ordering, ownership, failure, or synchronization semantics.

CPU, target, optimization settings, compiler contents, and the selected profile
contents participate in generated output cache identities. `build.coverage`
writes versioned per-function hit counts. `build.profile` consumes that data;
functions at or above one fifth of the peak count receive larger release
inlining limits and callers receive a larger inlining budget. A changed profile
invalidates affected output. No optimization choice alone guarantees a speedup;
performance claims require measurements on the target.

Instruction levels follow the compiler target definitions for
[x86](https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html),
[AArch64](https://gcc.gnu.org/onlinedocs/gcc/AArch64-Options.html) and
[RISC-V](https://gcc.gnu.org/onlinedocs/gcc/RISC-V-Options.html).
