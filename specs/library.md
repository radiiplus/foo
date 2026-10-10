# Library
Version: 1.

The standard library presents FOO declarations and FOO values. Import a module with `use name.` and qualify its members with `name.member`. Ordinary APIs contain no substrate prefixes, foreign build settings or backend types.

## Capability boundaries
| Level | Library responsibilities |
| --- | --- |
| Base | Collections, text, Unicode, structured data, compression, portable streams and networking, cryptographic services, testing |
| System | Explicit allocators, raw memory, foreign interfaces, processes, filesystem details, threads, tasks and atomics |
| Machine | Architecture operations, registers and instruction-level primitives |
| Hardware | Device interfaces, mapped registers, interrupts and explicit SIMD operations |

Levels are cumulative. A portable service may use a trusted native implementation without requiring its callers to author native code. An ordinary byte-stream operation therefore does not grant raw socket or register access. A target that cannot provide a service reports that incompatibility; it does not silently weaken the service.

## Values and ownership
Text represents UTF-8; untrusted input requires validation. Arbitrary input,
compressed data, keys and ciphertext belong in `sequence of byte`; they are not
valid text merely because they fit in a buffer. Whole-file binary operations
provide that type directly. Explicit stream and network operations return a
length-aware transport value that must be validated before text processing.
Unicode operations distinguish bytes, scalar values and grapheme clusters.

Collections preserve the declared element type. Bounds, iteration order, aliasing and ownership must be stated by each collection. Returning a view retains its owner's lifetime; returning an owned copy identifies the receiving allocator or scope. No API assumes that closing a container also owns and releases its elements.

Resources distinguish borrowed handles from owned handles. Owned resources have an explicit closing operation suitable for `after`; borrowed process streams cannot accidentally close the process's descriptors. Operations after close produce a defined failure or are rejected by lifetime checking.

## Errors and portability
Recoverable failures use `failable T` and the open Error identities. Optional absence uses `optional T`; an absent item is not automatically an error. APIs document which condition applies. No foreign error set appears in a FOO signature.

Portable APIs specify observable behavior consistently across targets: exact byte handling, size limits, short reads, end of input, cleanup and error categories. Cryptographic APIs require secure entropy and authenticated failure behavior; an unavailable secure implementation must fail rather than substitute an insecure one.

A module's exported declarations define its detailed API. This specification fixes the language-wide contracts; it does not require mirroring another language's standard library or introduce alternate syntax for library operations.

## Standard services

| Module | Operations |
| --- | --- |
| memory | Scope allocation; explicit owners; bounded byte transfer, clearing, value comparison and explicit pointer identity |
| io | Standard streams, bounded reads, line reads, writes, console display/report and close |
| file | Binary-safe file transfer; metadata and temporary files; directory and recursive cursors; locking and allocation; durable replacement; seek, position and size controls |
| net | TCP streams and socket controls; typed IPv4/IPv6 endpoints; UDP datagrams, connected peers, broadcast, multicast, unicast hops, traffic class, and socket buffers |
| dns | DNS record sets with TTL and borrowed answer views |
| adapter | Network interface address snapshots and MTU information |
| route | Routing snapshots with destinations, gateways, and metrics |
| http | Client requests and servers; request headers, redirects and connection reuse controls |
| process | Execute or spawn a program with typed arguments; own, inspect, wait for, or kill a child; pipe child standard streams; process identity and environment |
| thread | Spawn a function, wait for completion, mutexes and conditions |
| time | Raw monotonic nanoseconds plus typed instants, durations, sleep and measurement |
| timer | Owned cancellable one-shot timers with monotonic deadlines |
| calendar | Validated Gregorian dates, civil moments, and fixed UTC offsets |
| units | Dimension-checked quantities for application arithmetic |
| text | Concatenate, trim, split, adaptive find, byte length and copied byte ranges |
| sequence | Typed creation, append, removal, copying, sorting, sorted merging, stable partitioning, searching, deduplication, filtering and mapping |
| frame | Canonical length-prefixed binary payloads with bounded reads and owned results |
| block | Length-prefixed CRC32C blocks with bounded reads and owned results |
| bitmap | Persistent compact bits with checked lookup, update, count and release |
| heap | Persistent typed minimum-priority queue with peek, insert, remove and release |
| ring | Owned fixed-capacity byte deque with synchronized constant-time operations at both ends and explicit close |
| bloom | Owned bit-packed approximate membership for arbitrary byte keys, with insert, query and close |
| radix | Stable ascending sort of signed or unsigned 64-bit values into an independently owned sequence |
| matrix | Owned dense row-major decimal matrices; checked indexing, addition, product and column bias |
| tensor | Owned dense row-major decimal tensors; validated shapes, checked indexing, addition and scaling |
| arch | Processor operations and selected-target and runtime SIMD feature queries |
| cpu | Runtime-dispatched modular byte addition with a scalar fallback |
| gpu | Vulkan compute discovery, owned buffers and kernels, explicit transfers and checked workgroup dispatch |
| vulkan | Direct SPIR-V compute shader compilation, buffer bindings, and checked dispatch |
| log | Message and error output |
| metric | Owned synchronized counters, gauges, and bounded histograms with snapshots |
| trace | Thread-local nested spans with parent identity and monotonic duration |
| limit | POSIX process soft and hard limit queries and soft-limit updates |
| map, set, queue, stack | Typed immutable key/value lookup, unique values, FIFO and LIFO collections |
| table | Mutable open-addressed text-key lookup with typed values |
| codec | Explicit codec values plus portable generated JSON for scalars, optional values, sequences, choices, and records |
| checksum | Direct and incremental CRC32C over arbitrary byte sequences for corruption detection |
| binary | Canonical unsigned LEB128 and checked fixed-width little- or big-endian byte encoding |
| crypto | Binary and streaming SHA-256, streaming HMAC-SHA256, HKDF-SHA256, constant-time byte comparison, secure random data, authenticated encryption and signatures |
| state | An immutable state value paired with an application-defined failable transition |
| iterator | Explicit state-carrying iteration with item/done exhaustion |
| transaction | Prepare, commit, and rollback coordination for one-process work |
| contract | Runtime precondition, postcondition and invariant checks |
| testing | Assertions and bounded deterministic property checks |

Use `foo doc memory`, `foo doc sequence`, or `foo doc file.iv` to read public declarations. Documentation contains signatures and public types, not function bodies or private declarations.

`ring.create` requires positive capacity. `push` and `prepend` return false
when full; `pop`, `remove`, `first`, and `last` fail when empty. Calls are
synchronized, and `close`
releases the storage. `bloom.create` requires a positive bit count and 1 to 16
hash rounds. `contains` can return false positives but cannot return false for
an inserted key while the filter is open. Its hash is not suitable for
adversarial admission checks. Closed handles reject further calls. `radix.sort`
returns a separate sequence; the caller releases it with
`sequence.release[unsigned]`.
`radix.signed` sorts signed 64-bit integers, including both limits, with eight
stable byte passes; release its result with `sequence.release[integer]`.

`crypto.auth` creates an HMAC-SHA256 state for an arbitrary byte key.
`absorb` accepts chunks; `tag` returns an independently owned 32-byte tag and
`check` compares one in constant time. Either finalizes the state, and later
`absorb` calls fail. `discard` wipes and releases the state. `crypto.derive`
implements HKDF-SHA256 with separate binary secret, salt, and context, and
limits output to 8160 bytes. `crypto.compare` compares byte values in constant
time when their lengths match; lengths remain observable.

Sentence calls use the same exported functions as parenthesized calls. Imports and aliases apply normally:

```foo
use memory.
use io as io.
start {
  constant destination is allocate 4 try.
  copy "FOO!" into destination try.
  clear destination.
  io.display("Ready" plus newline).
}
```

Byte transfer rejects a short destination before writing anything and permits overlapping source and destination. `compare` returns -1, 0 or 1 using unsigned byte order. The allocator-based `memory.copy(owner, pointer, content)` also remains available for explicitly owned raw allocations; sentence copying accepts bounded sequences instead.

File modes are `"read"`, `"write"`, `"append"`, `"update"`, and `"create"`; create is exclusive. `read` returns up to the requested byte count; an empty result signals end of input. `line` removes the trailing line ending. `file.read` reads a whole file. A missing file fails. `directory` accepts an existing directory, but fails for an existing non-directory. Joining paths does not access the filesystem. An absolute right path replaces the left path. `exists` returns false only when the path is absent and propagates other inspection failures. `kind` returns owned `"file"`, `"directory"`, or `"other"` text. `metadata` returns an owned snapshot of size, kind, read-only status, and modified/accessed/metadata-change times in UTC nanoseconds. `temporary` exclusively creates an empty file and returns its owned path. `scan` and `walk` yield directory names and recursive relative paths, respectively; their cursors require explicit finish calls. Recursive traversal does not descend into links. `working` returns owned text. `copy` replaces the destination contents but does not provide the durability contract of `sync` plus `replace`.

TCP operations are blocking. Port zero asks the operating system to choose a port; `port` returns it. `send` completes the entire byte sequence or fails; `receive` may return fewer bytes than requested and returns empty at end of input. Closing a connection while another operation uses it requires caller synchronization.

`net.endpoint` pairs a host with a port. `lookup(host, family)` returns owned
numeric address text for `"any"`, `"ipv4"`, or `"ipv6"`; `resolve` includes the
port in an endpoint whose host must be released with `text.release`. These
operations return the first address. `dns.query(host, kind)` returns an owned
snapshot for A, AAAA, CNAME, NS, PTR, MX, SRV, or TXT records, including each
record's TTL. TXT character strings in one record are concatenated into at
most 511 bytes of text; longer records are omitted. `dns.count/name/data/kind/ttl` inspect it; names and data borrow
the snapshot until `dns.close`. `adapter.scan` and `route.scan` return owned
snapshots of local addresses, interface indices, MTUs, destinations, gateways,
and prefixes; release them with their module's `close`. UDP
`bind` and `local` manage local sockets; `transmit`/`deliver` send one entire
datagram or fail. `capture` consumes one datagram and returns a packet;
its `payload` byte view and `sender` text borrow the packet until `discard`.
If a packet exceeds the requested size, it is consumed and the operation
fails. Zero-length datagrams are valid. `dispose` releases a socket. Callers
must synchronize a close with concurrent socket operations.

`ipv4` and `ipv6` parse numeric addresses into typed values; `socket4`,
`socket6`, and `scoped6` construct typed endpoints. Typed TCP connect/listen
and UDP send operations accept these endpoints. `sender4` and `sender6` return
typed received addresses and fail on a family mismatch. `connect4` and
`connect6` associate a UDP socket with a peer; `emit` sends a whole
datagram to that peer and fails before association. Broadcast and multicast
membership, interface, hop, and loop controls require the matching socket
family. Advanced DNS records, resolver selection, and cancellable lookup are
tracked separately in the systems capability audit.

`net.unicast(socket, hops)` sets an IPv4 TTL or IPv6 unicast hop limit from 1
through 255. `net.traffic(socket, value)` sets an IPv4 TOS or IPv6 traffic
class byte from 0 through 255. Both return the effective value after the OS
applies the option; platforms can reject unsupported traffic classes.
`net.buffer(socket, direction, size)` sets a positive UDP socket buffer size,
and `net.capacity(socket, direction)` reads its effective size. Direction is
`"send"` or `"receive"`. The OS may clamp or enlarge a requested buffer.

`file.handle` and `net.handle` return borrowed, platform-specific unsigned handle values for system-level interoperation. On POSIX, these are a file descriptor and socket descriptor. On Windows, they are a Win32 `HANDLE` and Winsock `SOCKET`, respectively. They remain owned by the FOO resource, become invalid when it closes, and must not be closed or transferred to another owner by the caller. Native operations on them must be synchronized with FOO operations on the same resource. The native interface can use these values for platform-specific calls; portable code uses the regular file and network operations.

`push` performs one operating-system send and may report fewer bytes than supplied. `shutdown` accepts `read`, `write`, or `both` and does not release the connection. `latency` controls TCP_NODELAY and `probe` controls SO_KEEPALIVE. These options fail when the target socket or platform cannot provide the requested behavior.

Whole-file text uses `read` and `write`. Arbitrary binary files use
`load` and `save`; `load` returns an owned, length-aware
`sequence of byte` that must be passed once to `file.release`. File `seek` uses
signed byte offsets relative to `start`, `current`, or `end`. `position` and `size` return
byte counts; querying size preserves the current position. `flush` writes
process-buffered output without closing the stream and provides no stable-
storage guarantee. `sync` flushes and issues the platform's stable-storage
request. `replace` atomically renames a source over a destination on the same
filesystem where the host filesystem supplies atomic replacement; a
cross-filesystem replacement fails. The source should be synced and closed
first. POSIX implementations sync the destination parent after rename. Windows
implementations request write-through replacement. A failed `replace` does not
prove that the rename did not occur because a later durability request can
fail; callers inspect the destination before a retry. These operations report
successful operating-system requests, not a universal physical-media
guarantee. Remote, virtual, removable, or incorrectly configured storage may
provide weaker behavior. `remove` deletes a file and fails for a missing path,
but does not sync the parent directory and therefore has no durable-deletion
guarantee.

The file surface has no filesystem compare-and-swap operation. A publication protocol therefore permits one writer
per destination. Concurrent writers have last-successful-replacement behavior,
not arbitration. Reclamation after restart may enumerate candidates with
`scan` or `walk`; applications define the naming and recovery rules.
Append-mode writes remain positioned by the operating system's append
semantics.

`testing.fault` arms a one-shot current-thread file failure for `"write"`,
`"sync"`, or `"replace"`; `testing.clear` disarms it. An injected write limits
the byte count of one positioned store or writes that prefix before returning
an error from `io.write`. Injected sync and replace errors occur before the
host sync request and before rename, respectively. Child-process `exit` and
`abort` support deterministic crash tests.

HTTP client headers added with `attach` persist across requests and repeated names are preserved. `clear` removes them. Redirect limits range from 0 through 100; zero rejects redirects. Disabling `reuse` prevents a completed request connection from being retained for another request. Persistent headers can cross redirect trust boundaries, so callers must clear credentials before changing domains.

The Windows C backend uses WinHTTP and the operating-system trust store rather than requiring curl or OpenSSL. Its `trust` operation reports `CustomTrustUnavailable` because WinHTTP does not consume the portable PEM-file contract. Zig and POSIX HTTP clients support adding certificate files explicitly.

`process.execute` invokes its program directly and passes each `sequence of text` item as exactly one argument without shell parsing. It waits and returns the exit status; launch failure is a failable result. `process.run` invokes the host's command shell and returns its exit status; command text follows that shell's syntax. Argument zero names the executable. An absent environment variable fails with `MissingValue`. Windows paths and environment access currently follow the process's native character encoding.

`process.id` and `parent` report the current and parent process IDs;
`identity(child)` reports an owned child's ID while it remains open. IDs can
be reused after exit. `spawn` launches a program directly with the same
argument contract as `execute`, returning an owned child handle. `active`
polls without blocking and caches completion; `wait` blocks and returns the
cached exit status on later calls. POSIX signal exits use `128 + signal`.
`signal(child, name)` accepts `"kill"` and `"terminate"` on every hosted platform,
and `"interrupt"` and `"hangup"` on POSIX. Windows reports `MissingValue` for
those last two names. `kill` forcefully terminates a running child; `close`
terminates one that is
still active, waits for it, and releases its handle. Callers must serialize
operations on one child handle. `spawn` inherits standard streams. `pipe`
launches with separate stdin, stdout, and stderr pipes. `write` accepts binary
input and may report a partial write; call `seal` to signal end of input.
`read(child, "output" or "error", size)` returns one owned binary chunk, which
may be shorter than requested; an empty result means EOF. Size must be at most
16 MiB. Release each returned chunk with `process.release`. `close` also
closes any remaining pipe handles. Large simultaneous output and error streams
must both be drained to avoid blocking the child.

`thread.spawn` accepts a function value taking no arguments and giving nothing. Capturing closures are not supported. `wait` joins the task once; repeat waits fail with `Closed`. Protect shared mutation with a mutex. `pause(condition, mutex)` atomically releases a held mutex, waits, then reacquires it. Check the condition predicate in a loop because wakeups may be spurious. `signal` wakes one waiter. Close mutexes and conditions only after all users have finished. Outstanding tasks are joined when the program exits.

`time.current` is a monotonic timestamp in nanoseconds with an unspecified origin; subtract timestamps to measure elapsed time. Sleep accepts nanoseconds and may last longer than requested. `measure` runs a function once and returns elapsed nanoseconds. `instant` and `duration` wrap monotonic timestamps and spans; `nanos`, `millis`, and `seconds` construct a duration, `now` constructs an instant, `elapsed` subtracts ordered instants, and `wait` sleeps for a duration. Logging writes `INFO` or `ERROR`, the message, and a newline to the diagnostic stream.

`metric.create` accepts a nonempty name of at most 255 bytes and a `"counter"`, `"gauge"`, or `"histogram"` kind. Counters and gauges have no bounds. Histograms accept at most 64 strictly ascending inclusive upper bounds and include one overflow bucket. Counter and gauge addition, histogram count, and histogram sum fail before unsigned overflow. `set` applies only to gauges, `observe` only to histograms, and `bucket/count/sum` only to histograms. All instrument operations are synchronized; returned names and JSON `metric.export` snapshots are owned text and handles require `close`. The JSON snapshot includes histogram bounds, count, sum, and buckets.

`trace.begin` opens a named span of at most 255 bytes on the calling thread. `current`, `identity`, and `parent` expose span IDs; `finish` records a monotonic duration. Finish nested spans in reverse order and close each finished handle on its creating thread. A premature or out-of-order finish fails. `name` returns owned text. Spans do not implicitly propagate across threads or export themselves.

`limit.available/soft/hard/set` cover POSIX `"files"`, `"address"`, `"cpu"`, and `"stack"` resource limits where the OS provides them. CPU limits are seconds; the others are bytes except files, which is a count. The maximum unsigned value represents unlimited. `set` changes only the soft limit and asks the OS to enforce its ordinary hard-limit rules. On Windows, `available` is false and the operations report `MissingValue`. Unknown kinds fail as invalid input.

`timer.create` owns a one-shot timer. `arm` replaces its deadline relative
to the monotonic clock; zero delay expires immediately. `wait` returns true
after expiry and false when unarmed or cancelled; only one waiter may wait at
a time. `cancel` wakes a blocked waiter. `close` wakes the waiter and releases
the timer after it exits; callers must synchronize close with new operations.

`codec.codec[T]` contains application-supplied failable `encode` and `decode`
functions. `codec.encode[T]` and `codec.decode[T]` use the standard JSON wire
format and generate concrete handling for `T`. The cross-backend generated
contract is boolean, signed and unsigned integers, decimal, text, optional
values, sequences, choices, and records recursively containing only those
types. Sequences, including byte sequences, use JSON arrays; each byte is a
number from 0 through 255, while text uses a JSON string. Absent optional
values use JSON null, and a choice uses a one-field object keyed by its active
variant. A payload-free
variant's value is an empty object.
Generated parsing rejects invalid
syntax, duplicate or missing fields, wrong JSON kinds, and numeric overflow.
Pointer, function, and resource fields remain outside the
generated contract. Applications use an explicit `codec[T]` for those graphs.
No generated codec infers an
application schema version, size policy, ownership policy, or trust policy.
`binary.encode` writes canonical unsigned LEB128 in one to ten bytes.
`binary.decode` rejects truncated, overflowing, and nonminimal forms and
returns both the value and the offset following it. `binary.fixed` writes a
value in 1 through 8 bytes with `"little"` or `"big"` byte order and rejects a
value that cannot fit. `binary.parse` checks the source range and returns the
corresponding unsigned value. Both encoding calls return owned bytes for
`sequence.release[byte]`.
`zigzag.encode` maps signed 64-bit values through ZigZag and canonical
unsigned LEB128; `zigzag.decode` returns the signed value and next offset,
rejecting the same malformed, overflowing, and nonminimal forms as `decode`.
`hex.encode` emits lowercase hexadecimal text and `hex.decode` accepts only even
length lowercase pairs. `base64.encode` emits unpadded URL-safe Base64 and
`base64.decode` rejects padding, whitespace, alternate alphabets, bad lengths, and
nonzero unused tail bits. Encoded text is owned and uses `text.release`;
decoded bytes use `sequence.release[byte]`.
`bitmap` stores one bit per position in 64-bit words. Lookup and update reject
out-of-range indexes; `put` returns an independent bitmap and `release` frees
its words. `heap` is a persistent minimum-priority queue. `push` and `remove`
maintain heap order while copying the underlying sequence, so they use O(n)
storage and copying; each performs O(log n) comparisons. Release each version
that owns nonempty storage.
`frame.pack` writes a canonical unsigned length prefix followed by the payload.
`frame.read` takes an absolute offset and maximum payload length; it rejects
malformed prefixes, lengths over the limit, and truncated payloads before
allocating an independent copy. `block.pack` adds a trailing little-endian
CRC32C, and `block.read` verifies it before allocating its payload. Each read
returns a next offset for parsing concatenated values. Release returned packets
with their module's `release`; release packed bytes with
`sequence.release[byte]`. CRC32C detects accidental corruption, not malicious
modification. `sequence.lower` and `upper` return the first insertion positions
before and after equal values; `search` returns the first equal index or null.
All three require ascending sorted input and use O(log n) comparisons.
`state.machine[S, E]` contains a
current value and failable transition function; `step` returns a new machine and
does not mutate or persist the previous state. `contract` delegates `require`,
`ensure`, and `invariant` to the runtime assertion mechanism, so a failed check
is a panic rather than a recoverable `failable` value. `testing.every` invokes a
property with indexes from zero through `count - 1`; it is bounded enumeration,
not random input generation. `testing.generator[T]` maps those deterministic
indexes to typed values, and `testing.generate` checks a property for every
generated value.

`iterator.cursor[T, S]` stores explicit source state and an application-defined
failable pull function. `iterator.step[T, S]` contains `finished`, an optional
`value`, and the next state. `item` and `done` construct its two valid forms.
This protocol is explicit and does not make a custom cursor eligible for
`for each`.

`transaction.participant` groups prepare, commit, and rollback functions.
`transaction.execute` registers rollback after preparation and runs it when
work or commit propagates a failure. It provides no durability, nesting, or
distributed-commit guarantee.

## Collection values

Sequence edits leave the original logical value unchanged. Consecutive appends may share a backing buffer and write only beyond every older value's logical length; an append from an older version copies that version's prefix into an independent buffer. Other collection edits return independently owned backing storage. Element values are copied shallowly: pointers and nested collections retain their existing ownership. Release each retained operation result once, after all of its aliases stop using it; a plain assignment creates an alias, not another release obligation. Releasing a container does not release its elements. An empty collection needs no allocation. Unreleased backing storage is reclaimed at program exit. The full sequence representation and complexity contract is in [Persistent Sequences](sequences.md).

Maps and sets preserve insertion order and use linear equality searches. Updating an existing key preserves its position. Missing map keys fail with `Missing`. Queue `first` and stack `top` fail with `Empty`; removal from an empty collection fails. These collections prioritize predictable behavior over asymptotic performance. Edits copy O(n) elements.

`table` is the lookup-optimized alternative. It uses text keys, shallow-copies typed values, has O(1) average lookup and mutation, and does not define iteration order. Its handle is mutable and must be closed. Implementations use the same open-addressing behavior and error contract across backends, while hashing, allocation and byte transfer remain backend-native.

`sort[T]` requires `where T is Ord`, returns a stable sorted copy, and uses O(n log n) comparisons and O(n) scratch storage. `find[T]` requires `where T is Equatable` and returns an optional zero-based index. `deduplicate[T]` and its short alias `dedup[T]` preserve the first occurrence of each value. `reverse`, `take`, and `drop` each allocate one result sequence. `take` and `drop` reject counts beyond the input length. `any` and `all` short-circuit; `fold` combines values from first to last. Map keys and set elements require `Equatable`. Map `keys` and `values` allocate independent insertion-ordered sequences. Records can derive `Equatable` when all their fields support equality; equality compares fields and sequence contents, not storage addresses. Derived `Ord` compares fields in declaration order; sequences compare lexicographically and an absent optional precedes a present value. Transform functions accept ordinary function values; captured environments are not supported. `sequence.map` performs one result allocation. `filter` and `dedup` reserve once and compact once, so their allocation and copying work is O(n); deduplication still performs O(n²) equality comparisons.

`sequence.merge[T]` requires two ascending inputs and `Ord`. It returns a stable, independent copy in O(n + m) work, choosing the left item first on equal keys. `sequence.partition[T]` calls its predicate exactly once per input item and returns `division[T]` with stable `kept` and `rest` sequences. Both result sequences are independently owned and must each be released, including when empty. It uses O(n) work and O(n) temporary Boolean storage.

Text indexing and `length` count bytes, not characters. `trim` removes ASCII whitespace. `starts`, `ends`, and `contains` compare byte sequences and allocate nothing. `split` preserves empty fields, copies each field, rejects an empty separator, and allocates its result sequence once after counting the fields. Release each copied field with `text.release`, then the result sequence with `sequence.release`. Owned text returned by io, file, net, process and text uses `text.release`. Callers must validate untrusted stream and network results with `unicode.valid` before text processing. Byte ranges can split a multibyte character. Whole-file binary results instead use `sequence of byte` and `file.release`.
