# Performance

This page describes the current benchmark design, the sequence measurements
recorded on 2026-09-28, and the full backend comparison recorded on 2026-10-02
on an Intel Core i5-1145G7 Windows machine. Results apply to the listed
workloads and environment; they are not a general ranking of FOO, C, Zig, or
Rust.

## Measurement model

FOO builds each benchmark before timing begins. Runtime samples include process
startup and shutdown but exclude compilation. Reports retain every raw sample
along with the median, mean, 95th percentile, minimum, and maximum.

`startup.iv` measures the process and generated-program harness.
`runtime.iv` adds runtime initialization and one hosted query. Subtracting
either median from another workload is only an estimate because the samples
experience independent scheduler, frequency, scanning, and background-system
noise.

Handwritten controls in [`benchmark/native.c`](../benchmark/native.c),
[`benchmark/native.zig`](../benchmark/native.zig), and
[`benchmark/native.rs`](../benchmark/native.rs) perform the same observable work
as their FOO counterparts. They use the matching development or release mode,
keep meaningful call boundaries, and validate their final results. Version 4
reports include raw FOO-to-Rust median ratios, but only individual workloads may
be described as faster or slower; the report does not prove a language-wide
ranking.

## Workload coverage

| Workload | Measured boundary |
| --- | --- |
| `allocation` | Exact-size construction and transformation. |
| `arithmetic` | Checked loop control and arithmetic. |
| `branch` | Repeated append from a retained sequence version. |
| `calls` | Preserved private function calls. |
| `failure` | Successful failable calls and `try` propagation. |
| `generic` | Concrete generic specialization. |
| `growth` | Newest-version append plus one verified old-version branch. |
| `iteration` | Ordered traversal of one million sequence values. |
| `known` | Validation of a build-time-known value. |
| `lookup` | One million checked dynamic sequence lookups. |
| `runtime` | Runtime initialization and a hosted query. |
| `startup` | Process and generated-program startup. |

## Rust comparison

The checked-in [`benchmark/results.json`](../benchmark/results.json) uses the
`foo.benchmark/v4` schema and records two warmups, seven timed workload samples,
and 21 startup samples. Compilation is measured separately and excluded from
the runtime medians below.

| Workload | FOO/C release | FOO/Zig release | handwritten Rust release |
| --- | ---: | ---: | ---: |
| `allocation` | 14.89 ms | 11.08 ms | 41.05 ms |
| `arithmetic` | 47.89 ms | 34.47 ms | 43.82 ms |
| `branch` | 66.19 ms | 69.28 ms | 58.74 ms |
| `calls` | 35.53 ms | 62.00 ms | 55.80 ms |
| `failure` | 44.94 ms | 60.36 ms | 51.98 ms |
| `generic` | 21.56 ms | 35.36 ms | 35.46 ms |
| `growth` | 20.38 ms | 10.86 ms | 37.23 ms |
| `iteration` | 15.40 ms | 27.52 ms | 41.62 ms |
| `known` | 16.61 ms | 7.90 ms | 37.78 ms |
| `lookup` | 12.25 ms | 12.04 ms | 40.25 ms |
| `runtime` | 10.61 ms | 9.62 ms | 39.18 ms |
| `startup` | 43.98 ms | 32.90 ms | 39.97 ms |

FOO/C has a lower raw median than the Rust control in eight of the twelve
workloads; FOO/Zig also has a lower median in eight. FOO/C is slower here for
arithmetic, branch-heavy persistence, and startup. FOO/Zig is slower for the
branch, preserved-call, and failure workloads; its 0.10 ms generic advantage is
too small to treat as a stable win without more samples. These are
whole-process measurements, so startup and scheduler noise are material for
the shortest workloads. The raw samples in the report are the evidence; the
counts are not a claim that FOO is generally faster than Rust.

### Focused branch allocator measurement

The table above is the earlier full-suite snapshot. After that run, hosted Zig
executables that allocate sequences began linking libc and using its allocator.
A focused 2026-10-02 rerun of `branch` is recorded with all 20 timed samples in
[`benchmark/branch-allocator.json`](../benchmark/branch-allocator.json). Three
warmups preceded timing; the five release binaries ran as separate processes in
rotating sequential order on the same Intel Core i5-1145G7 Windows x64 machine.

| Build | Median | Minimum | 95th percentile |
| --- | ---: | ---: | ---: |
| Current FOO/Zig | 40.12 ms | 33.09 ms | 67.11 ms |
| Current FOO/C | 67.47 ms | 51.87 ms | 103.46 ms |
| Handwritten Rust | 80.18 ms | 34.23 ms | 168.82 ms |
| Direct Zig, page allocator | 89.34 ms | 74.47 ms | 159.67 ms |
| Direct Zig, C allocator | 56.34 ms | 45.41 ms | 91.20 ms |

The direct Zig pair uses the same generated branch program with only allocator
and libc-link selection changed. The C allocator reduced its median by about
37%, while adding 24,064 bytes to that pair's executable. The current FOO/Zig
build is a separate build with the compiler's release flags; its size is not
directly comparable to the direct Zig pair. The Rust result is a workload
control, not proof that FOO is generally faster. Background load varied during
these runs, so the raw samples and older full-suite snapshot should both remain
visible until a full report is rerun.

Arithmetic, calls, failure, and generic execute at least ten million loop
iterations so their work is larger than the process floor. The call and
failure helpers retain real call boundaries. Generic code remains eligible for
specialization because that is the behavior the workload measures.

### Focused arithmetic and loop checks

The full-suite table predates two further release-code changes. C now lowers
full-width checked addition through the compiler's overflow intrinsic where
available. Zig now emits a structured loop for a two-block loop with a direct
back edge and no phi nodes in either block. Other control-flow shapes continue
through the existing dispatcher. Both changes preserve checked arithmetic and
the call boundary in `calls` and `failure`.

Exploratory checks on the same Windows x64 machine used 40 timed process runs
per binary, four warmups, and rotating order within each workload. The Rust
control used `rustc -C opt-level=3`. These runs had substantial changes in
background load, so compare binaries within a row only; they do not replace
the full-suite report or establish a stable ordering against Rust.

| Workload | Earlier output | Updated output | Rust control |
| --- | ---: | ---: | ---: |
| C `arithmetic` | 39.10 ms | 37.41 ms | 33.36 ms |
| Zig `calls` | 131.74 ms | 107.80 ms | 100.19 ms |
| Zig `failure` | 158.94 ms | 123.92 ms | 113.33 ms |

The earlier and updated binaries within each row used the same source and
release settings. The Zig standard library suite passed after loop lowering;
manual signed and unsigned overflow checks and the C standard library suite passed after
the addition change. The remaining gaps are real in these runs, but the Rust
arithmetic control uses wrapping accumulation while FOO checks overflow, so
removing FOO's check solely to change the ranking would change the workload's
behavior.

## Sequence representation

A sequence value contains a data pointer and a logical length. Private runtime
metadata records the buffer's used length, capacity, element size, returned
result count, and retention by an older version.

Append follows three paths:

1. A newest view with spare capacity writes into the unused tail.
2. A newest view with a full buffer allocates geometric capacity and copies the
   logical contents once.
3. An older view allocates an independent geometric buffer and copies only its
   logical prefix.

Writing into the unused tail cannot change values visible through an older
logical length. Full growth keeps the prior buffer alive, and branching never
modifies the source buffer. Newest-version append is therefore amortized O(1),
while append from an older version is O(n) in that version's length. Lookup is
O(1), and ordered iteration is O(n).

The C runtime indexes owned sequence metadata by data pointer. The Zig runtime
uses its retained-allocation hash map. Unrelated allocations therefore do not
turn newest-version append into an allocation-list scan.

## Runtime telemetry

Benchmark builds enable the counters below. Ordinary builds compile out their
updates and do not print benchmark telemetry. Payload counters exclude runtime
metadata, compiler memory, and operating-system bookkeeping.

| Counter | Meaning |
| --- | --- |
| `allocations` | Successful payload allocations. |
| `allocatedBytes` | Total requested payload bytes. |
| `reallocations` | Payload resize operations. |
| `bytesCopied` | Bytes copied through measured transfer paths. |
| `growthOperations` | Persistent append operations. |
| `growthBytesCopied` | Bytes copied specifically by append. |
| `averageCapacity` | Mean reserved capacity observed by append. |
| `maximumCapacity` | Largest reserved sequence capacity. |
| `growthFactor` | Reserved capacity divided by requested logical length. |
| `liveBytes` | Payload bytes still owned when telemetry is reported. |
| `peakBytes` | Highest simultaneous payload-byte count. |
| `olderVersionBytes` | Live buffer bytes retained for older versions. |
| `slowPathHits` | Appends that allocated a buffer. |
| `branchOperations` | Appends detected from older logical lengths. |
| `branchBytesCopied` | Prefix bytes copied by those branch appends. |

Compiler telemetry separately reports generic specializations, inlined calls,
eliminated bounds checks, allocations and boundaries, fused pipelines, and
specialized continuations and serialization. A zero reports observed compiler
behavior; it does not imply that an optimization is unnecessary.

## Executable footprint

Release emission removes program and runtime work before backend compilation.
Reachability (following calls from an entry point) retains executable entries,
exported ABI functions, and everything they can call. Unused imported
functions, runtime declarations, native fragments, storage, and traces are not
emitted. Runtime providers are then selected from the remaining calls, so a
file or network implementation is absent from a program that only writes to a
terminal.

The C release path uses collectable function/data sections and the native
dead-code option for GNU, Darwin, or MSVC linkers. MSVC-targeted release builds
also disable incremental linking and debug output. Zig release builds are
stripped, use a minimal service stub when no native service is reached, and do
not initialize allocator or library cleanup for an empty program. Static and
shared libraries preserve public functions because callers outside the current
module remain possible.

On the Windows measurement host used for this page, a release C hello-world
artifact decreased from 805,376 bytes to 145,408 bytes after target-correct
linking and selective service emission. An empty FOO/C executable is 109,056
bytes, exactly matching the handwritten empty C control under the same Clang
and linker settings. These numbers describe this toolchain and target only;
format, system library, and linker differences change executable size on other
platforms.

## Sequence results

Raw focused samples and counters are stored in
[`benchmark/sequence.json`](../benchmark/sequence.json). These are release
builds with compilation excluded and process startup included.

| Workload | Work | FOO to C median | FOO to Zig median |
| --- | --- | ---: | ---: |
| `growth` | 10,000 newest appends plus one old-version append | 35.94 ms | 23.01 ms |
| `branch` | 1,000 appends from a retained 5,000-element version | 367.36 ms | 377.33 ms |
| `lookup` | 1,000,000 checked dynamic lookups | 148.81 ms | 45.29 ms |
| `iteration` | Construct and iterate 1,000,000 values | 48.41 ms | 44.71 ms |

The `growth` workload reports the same counters through both backends:

```text
allocations             13
allocated bytes         327,616
bytes copied            171,008
growth operations       10,001
slow-path hits          13
branch operations       1
branch bytes copied     40,000
peak payload bytes      327,616
older-version bytes     131,008
```

The explicit branch allocates a 65,536-byte buffer and copies 40,000 bytes.
The newest-version chain uses 12 allocations and copies 131,008 bytes at its
capacity boundaries.

`branch` deliberately exercises the expensive persistence path. Its 1,000
branches copy 40,000,000 prefix bytes. `lookup` uses one 80,000-byte allocation
and no copies. `iteration` uses one 8,000,000-byte allocation and no copies.

Growth uses five timed samples per backend; the other focused workloads use
three. The Zig lookup distribution contains a 449.53 ms sample, so the median
must be read alongside the raw samples rather than treated as a stable language
constant.

## Current decisions

The shared-tail representation is the default because it fits the measured
newest-version growth workload while preserving older logical values. A chunked
persistent sequence and a persistent vector/tree remain candidates for
branch-heavy workloads. Either candidate needs parity coverage and benchmark
evidence for lookup, iteration, memory retention, and branch cost before it can
be selected.

Hosted Zig executables that allocate sequences now link libc and use its
allocator. Other targets keep the page allocator when libc is unavailable.
Sequence buffers still use the common runtime allocation interface and retain
the same ownership rules. Region allocation, size classes, or a separate
large-object path remain candidates only after representative profiling.

Other measurable candidates include proven bounds-check elimination,
loop-aware inlining, map-loop fusion, allocation placement after escape
analysis, and in-process measurements for operations smaller than the process
floor. Architecture-specific instructions or assembly require profiling
evidence after representation, algorithm, copying, and lifetime work have been
addressed.
