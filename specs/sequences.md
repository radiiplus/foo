# Persistent Sequences

This document defines the storage contract used by `sequence`. Generated code
still represents a sequence as a data pointer and a logical length. Capacity
and ownership metadata are private runtime details. This does not make a
sequence valid for by-value C interoperation.

## Observable rule

An update returns a new logical sequence. Every older value keeps its original
length and values. Code may read an older value after newer values have been
created, and it may append from that older value to create an independent
branch.

For an append, the runtime follows three cases:

1. When the input length equals the buffer's used length and spare capacity is
   available, write only in the unused tail and return a view whose length is
   one larger.
2. When the input is newest but the buffer is full, allocate geometric
   capacity, copy the input once, append, and leave the old buffer alive.
3. When the input length is less than the buffer's used length, it is an older
   version. Allocate a new geometric buffer, copy only that version's prefix,
   and append there.

The first case cannot change anything visible through an older value because
the write is beyond every older logical length. The second and third cases do
not modify the old buffer. A sequence whose storage is borrowed or not
recognized by the runtime always uses the copying case.

Repeated append to the newest result is amortized O(1). Appending from an older
version is O(n) in that version's length. Lookup remains O(1), and ordered
iteration remains O(n).

## Ownership and release

Each sequence-producing operation result represents one releasable result.
Results created by consecutive appends may share one buffer. The runtime counts
those results and frees the buffer only after their releases are accounted for.
An ordinary assignment is an alias, not a new result, and does not create an
extra release obligation.

Call `sequence.release` once for each operation result that is still retained,
after all aliases of that result have stopped being used. Reassigning a dynamic
name does not release its previous value automatically. Any unreleased buffers
are reclaimed during runtime shutdown. Releasing a sequence never releases
objects referenced by its elements.

## Runtime metadata

Owned sequence buffers record element size, used length, capacity, returned
result count, and whether the buffer is retained for an older version. The
element size is specialized when the generic sequence operation is compiled;
it is not rediscovered from element values at runtime. Capacity multiplication
and geometric growth are checked for overflow.

Benchmark builds enable and report payload allocations, allocated and copied
bytes, growth operations, slow-path hits, live and peak bytes, bytes retained
for older versions, and branch operations and copies. Ordinary builds compile
out counter updates and do not print benchmark telemetry.

## Representation alternatives

| Representation | Newest append | Branch append | Lookup | Status |
| --- | --- | --- | --- | --- |
| Shared buffer with mutable tail | Amortized O(1) | O(n) prefix copy | O(1) | Implemented default |
| Persistent chunks | Amortized O(1) | Shares completed chunks | O(1) with extra arithmetic | Design fallback for branch-heavy evidence |
| Persistent vector/tree | O(log n) | O(log n) path copy | O(log n) | Design fallback for large, branch-heavy evidence |

The shared-buffer representation is selected because the measured regression
is repeated newest-version append. Chunked or tree storage requires its own
parity suite and benchmark evidence before selection. Persistence must not be
replaced by an ordinary mutable vector.

## Allocator boundary

Sequence buffers use the existing runtime allocation interface and remain
separately identified in its metadata. This change does not introduce a bump,
slab, size-class, large-object, or assembly allocator. Allocator redesign is
justified only after profiling attributes a material share of a representative
workload to allocation itself; a working threshold for investigation is about
10 to 15 percent.
