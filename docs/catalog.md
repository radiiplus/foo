# Standard Library Index

This page answers two questions: which module should you import, and how much
control does it expose? Use the focused module source under `lib/` as the exact
signature reference for the installed compiler version.

## Everyday modules

| Module | Purpose | Common operations |
| --- | --- | --- |
| `io` | Standard and file streams; `display` converts codec-supported values | bare console `display`/`report`; stream `input`/`output`/`report`, `read`, `line`, `write`, `close` |
| `file` | Text and binary files, inspection, copying, same-filesystem replacement, directories, and stream position | `open`, `read`, `write`, `load`, `save`, `release`, `exists`, `kind`, `copy`, `working`, `remove`, `replace`, `sync`, `seek`, `position`, `size` |
| `text` | Owned text operations and byte-oriented predicates | `concatenate`, `trim`, `length`, `slice`, `find`, `starts`, `ends`, `contains`, `split`, `release` |
| `json` | JSON documents and streaming | `parse`, `write`, `field`, `item`, `kind`, `size`, `set`, `append`, `stream`, `feed`, `next`, `data`, `close` |
| `time` | Raw and typed monotonic time (measured by a clock that does not move backward) | `current`, `sleep`, `measure`, `nanos`, `millis`, `seconds`, `now`, `elapsed`, `wait` |
| `timer` | Owned cancellable one-shot timers | `create`, `arm`, `wait`, `cancel`, `close` |
| `process` | Direct execution, child control and pipes, identity, arguments, and environment | `execute`, `run`, `spawn`, `pipe`, `write`, `read`, `seal`, `release`, `active`, `wait`, `poll`, `kill`, `close`, `id`, `parent`, `identity` |
| `system` | Host information | `cores`, `host`, `page` |
| `log` | Application messages | `note`, `alert` |
| `metric` | Owned synchronized counters, gauges, and histograms | `create`, `add`, `set`, `observe`, `value`, `count`, `sum`, `bucket`, `name`, `close` |
| `trace` | Nested monotonic spans on one thread | `begin`, `current`, `identity`, `parent`, `name`, `finish`, `elapsed`, `close` |
| `limit` | POSIX process resource limits | `available`, `soft`, `hard`, `set` |

The filesystem module is `file`. Directory enumeration, advisory locks, and
exclusive creation are available. `sync` plus same-filesystem `replace` supports
a one-writer publication protocol; compare-and-swap replacement remains open.
Exact storage guarantees and caveats are in
[The Standard Library](library.md#2-files-and-paths-file).

## Collections

| Module | Storage model | Main operations |
| --- | --- | --- |
| `sequence` | Persistent (updates return a new value) typed sequence | `create`, `append`, `remove`, `copy`, `length`, `find`, `lower`, `upper`, `search`, `sort`, `merge`, `unite`, `intersect`, `difference`, `filter`, `partition`, `map`, `reverse`, `any`, `all`, `fold`, `take`, `drop`, `deduplicate`, `release` |
| `bitmap` | Persistent compact bits | `create`, `get`, `put`, `toggle`, `invert`, `count`, `merge`, `intersect`, `difference`, `symmetric`, `rank`, `select`, `next`, `previous`, `release` |
| `heap` | Persistent minimum-priority values | `create`, `build`, `first`, `push`, `remove`, `merge`, `replace`, `pop`, `sorted`, `length`, `release` |
| `ring` | Owned bounded byte deque with synchronized operations | `create`, `push`, `prepend`, `pop`, `remove`, `first`, `last`, `length`, `capacity`, `close` |
| `bloom` | Owned bit-packed membership filter for byte keys | `create`, `add`, `contains`, `bits`, `rounds`, `close` |
| `radix` | Independent ascending signed or unsigned sort result | `sort`, `signed` |
| `matrix` | Owned dense row-major decimal matrix | `create`, `get`, `add`, `product`, `hadamard`, `bias`, `transpose`, `crop`, `sum`, `release` |
| `tensor` | Owned dense row-major decimal tensor | `create`, `build`, `rank`, `get`, `add`, `scale`, `hadamard`, `broadcast`, `reshape`, `permute`, `crop`, `concat`, `sum`, `release` |
| `map` | Persistent ordered generic key/value map | `create`, `get`, `contains`, `put`, `remove`, `keys`, `values`, `length`, `release` |
| `table` | Mutable native text-keyed map | `create`, `get`, `contains`, `put`, `remove`, `length`, `close` |
| `set` | Persistent unique values with equality-based algebra | `create`, `insert`, `contains`, `remove`, `unite`, `intersect`, `difference`, `symmetric`, `subset`, `length`, `release` |
| `queue` | Persistent first-in/first-out values | `create`, `append`, `first`, `remove`, `length`, `release` |
| `stack` | Persistent last-in/first-out values | `create`, `push`, `top`, `remove`, `length`, `release` |
| `list` | Mutable list of borrowed byte pointers | `create`, `push`, `get`, `length`, `close` |

Prefer the persistent generic collections (collections that work with several
types and return new values when updated) for ordinary application data. Use
the mutable or pointer-oriented modules when their ownership (who must release
storage) and ordering
contracts match the workload.

`ring.push` and `prepend` return false when full; `pop` and `remove` fail when empty. `bloom`
may report a match for an absent key, but never misses an inserted key while
open. Close both handles after use. `radix.sort` returns a new sequence that
the caller releases with `sequence.release[unsigned]`. `radix.signed` returns
an independent signed sequence released with `sequence.release[integer]`.

## Networking

| Module | Level | Capabilities |
| --- | --- | --- |
| `http` | HTTP client and server | Client requests, headers, redirects, reuse, response status/body, server listen/accept/read/reply. |
| `net` | TCP and UDP sockets | Connect, listen, datagrams, typed endpoints, multicast, broadcast, hop limits, traffic class, socket buffers, timeouts, and IPv4 UDP interface selection. |
| `tls` | Verified client TLS streams | Availability, connect, send, receive, timeout, and close; requires an OpenSSL runtime. |
| `ipc` | File-backed shared regions | Exclusive create, join, borrowed byte views, advisory lock, unlock, and close. |
| `poll` | Socket readiness and deadlines | Owned poller with TCP/UDP receive or send watches, one-shot monotonic deadlines, token removal, and bounded waits. |
| `dns` | DNS answers | Record query, count, name, data, kind, TTL, and close. |
| `adapter` | Network interfaces | Snapshot assigned addresses, families, indices, and MTUs. |
| `route` | Routes | Snapshot destinations, gateways, prefixes, indices, and metrics. |

`tls.available` checks whether a compatible OpenSSL library can be loaded.
Set `FOO_TLS_LIBRARY` to its absolute path when it is outside the default
loader locations. `tls.connect` verifies the peer against OpenSSL's default
trust roots and the requested hostname; `SSL_CERT_FILE` can select a trust
bundle for a process.

The simple HTTP path chooses conservative defaults:

```foo
use http as web.

constant client is web.client try.
after { web.close(client). }
constant response is web.request(client, "https://example.com", "GET", "", 1048576) try.
after { web.release(response). }
constant body is web.body(response) try.
```

Advanced users can configure the same client before requesting:

```foo
use http as web.

constant client is web.client try.
after { web.close(client). }
web.attach(client, "Accept", "application/json") try.
web.redirects(client, 2) try.
web.reuse(client, true).
```

This layered API keeps common code short without hiding protocol controls.

## Data, encoding, and security

| Module | Purpose | Main operations |
| --- | --- | --- |
| `crypto` | Binary hashing, message authentication, key derivation, constant-time comparison, random bytes, encryption, signatures, passwords | `digest`, `begin`, `auth`, `absorb`, `tag`, `check`, `discard`, `derive`, `compare`, `random`, `seal`, `open`, `sign`, `verify` |
| `checksum` | CRC32C corruption detection for binary data | `compute`, `begin`, `update`, `result`, `close` |
| `binary` | Canonical unsigned variable integers and fixed-width endian integers | `encode`, `decode`, `fixed`, `parse` |
| `packing` | Canonical binary flags, byte runs, and sorted unsigned deltas | `bits`, `expand`, `runs`, `unroll`, `deltas`, `restore` |
| `frame` | Bounded length-prefixed binary payloads | `pack`, `read`, `release` |
| `block` | Bounded CRC32C-checked binary payloads | `pack`, `read`, `release` |
| `compress` | Whole-value gzip/zlib and bounded framed block streams | `pack`, `unpack`, `encode`, `decode` |
| `unicode` | Unicode validation and conversion | `scan`, `next`, `valid`, `points`, `wide`, `narrow`, `release` |
| `buffer` | Release converted buffers | `free`, `words`, `points` |
| `codec` | Application-defined typed conversion plus portable generated JSON for scalar, optional, sequence, choice, and record values | `codec[T]`, `encode[T]`, `decode[T]` |

Cryptographic calls can fail and must use postfix `try` or a deliberate
fallback. Do not invent keys or nonces by formatting ordinary application
values; use the module's key and random facilities.

## Memory and machine access

| Module | Purpose | Main surface |
| --- | --- | --- |
| `memory` | Allocators (objects that reserve and release memory) and owned memory | `system`, `arena`, `allocate`, `expand`, `release`, `copy`, `view`, `close`, `transfer`, `clear`, `compare`, `identical` |
| `virtual` | Page-backed regions with whole-region protection | `reserve`, `size`, `commit`, `protect`, `decommit`, `load`, `store`, `release` |
| `atomic` | Shared atomic unsigned values | `create`, `load`, `store`, `add`, `swap`, `replace`, `release` |
| `arch` | Processor utilities and build/runtime SIMD queries | `count`, `pause`, `ticks`, `target`, `runtime`, `prefetch`, `stage` |
| `cpu` | Runtime-dispatched byte addition | `add` |
| `topology` | Online logical CPUs, current processor, and scoped thread affinity | `count`, `current`, `pin`, `restore` |
| `gpu` | Vulkan compute with checked FOO kernels and explicit ownership | `available`, `open`, `reserve`, `upload`, `download`, `prepare`, `bind`, `dispatch`, `finish`, `discard`, `dispose`, `close` |
| `vulkan` | Direct SPIR-V compute shader execution with explicit bindings | `count`, `select`, `compile`, `bind`, `dispatch`, `plane`, `volume` |
| `stream` | Pointer-oriented byte streams | `input`, `output`, `report`, `read`, `write`, `print`, `close` |

These modules are advanced surfaces. Their pointer, lifetime (how long data
remains valid), memory-order (when workers observe shared changes), or
platform requirements belong in the calling API's documentation.

## Concurrency (overlapping work)

| Module | Purpose | Main surface |
| --- | --- | --- |
| `task` | Runtime-selected work and asynchronous networking (work continues while networking waits) | Executors, channels, scopes, pools, affinity, and socket operations. |
| `thread` | Operating-system threads | `spawn`, `wait`, mutex (single-worker lock), condition, signal, pause, and close operations. |
| `atomic` | Lock-free shared counters | Explicitly ordered atomic operations (shared changes completed as one step). |

Start with tasks for independent application work. Use threads and atomics when
an operating-system thread or shared-memory protocol is specifically required.

## Development support

| Module | Purpose | Main operations |
| --- | --- | --- |
| `testing` | Test assertions | `expect`, generic `same`, `every`, `generator[T]`, `generate[T]` |
| `contract` | Application preconditions (rules required before work starts) and invariants (rules that must always remain true) | `require`, `ensure`, `invariant` |
| `state` | Immutable checked state transitions | `machine[S, E]`, `create`, `step` |

`testing.every` checks a Boolean property for a bounded range of unsigned
indexes. It is deterministic enumeration (the same range is checked in the
same order), not automatic type-driven input
generation.

The test runner, benchmark runner, package manager, formatter, and language
server are CLI tools rather than source modules.

## Reading a signature

Consider this signature fragment from the HTTP module. `Peer` is an opaque
module-owned opaque type:

```foo
public define Peer as opaque.

public use "http" function read(
  value pointer to Peer,
  limit unsigned 32
) giving failable text.
```

This means:

1. The operation is public from the `http` module.
2. It receives a peer handle and an explicit byte limit.
3. Success produces owned text.
4. Failure must be propagated or handled.

Limits, ownership, ordering, accepted string values, and cleanup requirements
are part of an API contract even when the type alone cannot express all of
them.

See [The standard library](library.md) for guided examples and
[Advanced FOO](advanced.md) for low-level policy controls.
