# Standard Library Index

This page answers two questions: which module should you import, and how much
control does it expose? Use the focused module source under `std/` as the exact
signature reference for the installed compiler version.

## Everyday modules

| Module | Purpose | Common operations |
| --- | --- | --- |
| `io` | Standard and file streams | `input`, `output`, `report`, `read`, `line`, `write`, `close`, `display` |
| `file` | Files, directories, and stream position | `open`, `read`, `write`, `directory`, `join`, `flush`, `seek`, `position`, `size` |
| `path` | Low-level path inspection | `merge`, `parent`, `name`, `suffix`, `absolute` |
| `text` | Owned text operations | `concatenate`, `trim`, `length`, `slice`, `find`, `split`, `release` |
| `json` | JSON documents and streaming | `parse`, `write`, `field`, `item`, `kind`, `size`, `set`, `append`, `stream`, `feed`, `next`, `data`, `close` |
| `time` | Raw and typed monotonic time (measured by a clock that does not move backward) | `current`, `sleep`, `measure`, `nanos`, `millis`, `seconds`, `now`, `elapsed`, `wait` |
| `random` | Random data | `default`, `bytes`, `number` |
| `process` | Process and argument access | `run`, `count`, `argument`, `environment` |
| `system` | Host information | `cores`, `host`, `page` |
| `log` | Application messages | `note`, `alert` |

The canonical (official standard) filesystem module is `file`. Application documentation and new
code do not use the old `fs` name.

## Collections

| Module | Storage model | Main operations |
| --- | --- | --- |
| `sequence` | Persistent (updates return a new value) typed sequence | `create`, `append`, `remove`, `copy`, `length`, `find`, `sort`, `filter`, `map`, `deduplicate`, `release` |
| `map` | Persistent ordered generic key/value map | `create`, `get`, `contains`, `put`, `remove`, `length`, `release` |
| `table` | Mutable native text-keyed map | `create`, `get`, `contains`, `put`, `remove`, `length`, `close` |
| `set` | Persistent unique values | `create`, `insert`, `contains`, `remove`, `length`, `release` |
| `queue` | Persistent first-in/first-out values | `create`, `append`, `first`, `remove`, `length`, `release` |
| `stack` | Persistent last-in/first-out values | `create`, `push`, `top`, `remove`, `length`, `release` |
| `list` | Linked values | Creation, traversal, insertion, removal, and release. |
| `deque` | Low-level double-ended queue | `create`, `front`, `back`, `shift`, `pop` |
| `heap` | Low-level priority storage | `create`, `insert`, `extract`, `peek` |
| `index` | Low-level text lookup | `create`, `register`, `lookup`, `known` |
| `bits` | Mutable bit collection | `create`, `enable`, `disable`, `enabled` |

Prefer the persistent generic collections (collections that work with several
types and return new values when updated) for ordinary application data. Use
the mutable or pointer-oriented modules when their ownership (who must release
storage) and ordering
contracts match the workload.

## Networking

| Module | Level | Capabilities |
| --- | --- | --- |
| `http` | HTTP client and server | Client requests, headers, redirects, reuse, response status/body, server listen/accept/read/reply. |
| `net` | TCP sockets | Connect, listen, accept, complete/partial send, receive, shutdown, no-delay, keepalive, close. |

The simple HTTP path chooses conservative defaults:

```foo
use http as web.

constant client is web.client() try.
after { web.close(client). }
constant response is web.request(client, "https://example.com", "GET", "", 1048576) try.
after { web.release(response). }
constant body is web.body(response) try.
```

Advanced users can configure the same client before requesting:

```foo
use http as web.

constant client is web.client() try.
after { web.close(client). }
web.attach(client, "Accept", "application/json") try.
web.redirects(client, 2) try.
web.reuse(client, true).
```

This layered API keeps common code short without hiding protocol controls.

## Data, encoding, and security

| Module | Purpose | Main operations |
| --- | --- | --- |
| `crypto` | Hashing, random bytes, authenticated encryption, signatures, passwords | `hash`, `random`, `seal`, `open`, `key`, `sign`, `verify`, `password`, `confirm` |
| `compress` | Compression with explicit format and output limits | `pack`, `unpack` |
| `unicode` | Unicode validation and conversion | `scan`, `next`, `valid`, `points`, `wide`, `narrow`, `release` |
| `buffer` | Release converted buffers | `free`, `words`, `points` |
| `format` | Low-level formatted data | `format`, `parse` |
| `codec` | Typed text conversion and generated JSON | `Codec[T]`, `encode[T]`, `decode[T]` |

Cryptographic calls can fail and must use postfix `try` or a deliberate
fallback. Do not invent keys or nonces by formatting ordinary application
values; use the module's key and random facilities.

## Memory and machine access

| Module | Purpose | Main surface |
| --- | --- | --- |
| `memory` | Allocators (objects that reserve and release memory) and owned memory | `system`, `arena`, `allocate`, `expand`, `release`, `copy`, `view`, `close`, `transfer`, `clear`, `compare`, `identical` |
| `atomic` | Shared atomic unsigned values | `create`, `load`, `store`, `add`, `swap`, `replace`, `release` |
| `arch` | Processor utilities | `count`, `pause`, `ticks` |
| `dl` | Dynamic libraries | `open`, `symbol`, `unload` |
| `env` | Low-level environment access | `variable` |
| `stream` | Pointer-oriented byte streams | `input`, `output`, `report`, `read`, `write`, `print`, `close` |

These modules are advanced surfaces. Their pointer, lifetime (how long data
remains valid), memory-order (when workers observe shared changes), or
platform requirements belong in the calling API's documentation.

## Concurrency (overlapping work)

| Module | Purpose | Main surface |
| --- | --- | --- |
| `task` | Runtime-selected work and asynchronous networking (work continues while networking waits) | Executors, channels, scopes, pools, affinity, and socket operations. |
| `thread` | Operating-system threads | `spawn`, `wait`, mutex (single-worker lock), condition, signal, pause, and close operations. |
| `sync` | Low-level synchronization (worker coordination) records | Mutex creation, lock, and unlock; additional record types are reserved for the growing surface. |
| `atomic` | Lock-free shared counters | Explicitly ordered atomic operations (shared changes completed as one step). |

Start with tasks for independent application work. Use threads and atomics when
an operating-system thread or shared-memory protocol is specifically required.

## Platform-specific modules

| Module | Platform | Examples |
| --- | --- | --- |
| `os.unix` | Unix-like systems | Pipes, signals, memory mapping. |
| `os.windows` | Windows | Handles, process access, Registry, WinRT. |

Importing a platform module makes the platform dependency explicit. Portable
packages should keep that code behind a small module boundary.

## Development support

| Module | Purpose | Main operations |
| --- | --- | --- |
| `testing` | Test assertions | `expect`, `same`, `number`, `positive`, `real`, `point` |
| `contract` | Application preconditions (rules required before work starts) and invariants (rules that must always remain true) | `require`, `ensure`, `invariant` |
| `state` | Immutable checked state transitions | `Machine[S, E]`, `create`, `step` |

`testing.every` checks a Boolean property for a bounded range of unsigned
indexes. It is deterministic enumeration (the same range is checked in the
same order), not automatic type-driven input
generation.

The test runner, benchmark runner, package manager, formatter, and language
server are CLI tools rather than source modules.

## Reading a signature

Consider this signature fragment from the HTTP module. `Peer` is an opaque
module-owned type declared elsewhere in that module:

<!-- snippet: context -->
```foo
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
