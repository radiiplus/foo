# Performance

This page describes the current benchmark design and the measurements recorded
on 2026-09-28 on an Intel Core i5-1145G7 Windows machine. Results apply to the
listed workloads and environment; they are not a general ranking of FOO, C, or
Zig.

## Measurement model

FOO builds each benchmark before timing begins. Runtime samples include process
startup and shutdown but exclude compilation. Reports retain every raw sample
along with the median, mean, 95th percentile, minimum, and maximum.

`startup.iv` measures the process and generated-program harness.
`runtime.iv` adds runtime initialization and one hosted query. Subtracting
either median from another workload is only an estimate because the samples
experience independent scheduler, frequency, scanning, and background-system
noise.

Handwritten controls in [`benchmark/native.c`](../benchmark/native.c) and
[`benchmark/native.zig`](../benchmark/native.zig) perform the same observable
work as their FOO counterparts. They use the matching development or release
mode, keep meaningful call boundaries, and validate their final results.

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

Arithmetic, calls, failure, and generic execute at least ten million loop
iterations so their work is larger than the process floor. The call and
failure helpers retain real call boundaries. Generic code remains eligible for
specialization because that is the behavior the workload measures.

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

Allocator redesign is deferred. Sequence buffers continue to use the common
runtime allocation interface, and their behavior remains independently
measurable. Region allocation, size classes, or a separate large-object path
should be considered only after profiling attributes a material share, roughly
10 to 15 percent or more, of a representative workload to allocator overhead.

Other measurable candidates include proven bounds-check elimination,
loop-aware inlining, map-loop fusion, allocation placement after escape
analysis, and in-process measurements for operations smaller than the process
floor. Architecture-specific instructions or assembly require profiling
evidence after representation, algorithm, copying, and lifetime work have been
addressed.
