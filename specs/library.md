# Library
Version: 1.

The standard library presents FOO declarations and FOO values. Import a module with `use name.` and qualify its members with `name.member`. Ordinary APIs contain no substrate prefixes, foreign build settings or backend types.

## Capability boundaries
| Level | Library responsibilities |
| --- | --- |
| Base | Collections, text, Unicode, formatting, structured data, compression, portable streams and networking, cryptographic services, testing |
| System | Explicit allocators, raw memory, foreign interfaces, processes, filesystem details, dynamic loading, threads, tasks and atomics |
| Machine | Architecture operations, registers and instruction-level primitives |
| Hardware | Device interfaces, mapped registers, interrupts and explicit SIMD operations |

Levels are cumulative. A portable service may use a trusted native implementation without requiring its callers to author native code. An ordinary byte-stream operation therefore does not grant raw socket or register access. A target that cannot provide a service reports that incompatibility; it does not silently weaken the service.

## Values and ownership
Text represents UTF-8; untrusted input requires validation. Arbitrary input, compressed data, keys and ciphertext belong in `sequence of byte`; they are not valid text merely because they fit in a buffer. The v0 service interfaces still carry byte data through the text representation, as detailed below. Unicode operations distinguish bytes, scalar values and grapheme clusters.

Collections preserve the declared element type. Bounds, iteration order, aliasing and ownership must be stated by each collection. Returning a view retains its owner's lifetime; returning an owned copy identifies the receiving allocator or scope. No API assumes that closing a container also owns and releases its elements.

Resources distinguish borrowed handles from owned handles. Owned resources have an explicit closing operation suitable for `after`; borrowed process streams cannot accidentally close the process's descriptors. Operations after close produce a defined failure or are rejected by lifetime checking.

## Errors and portability
Recoverable failures use `fallible T` and the open Error identities. Optional absence uses `optional T`; an absent item is not automatically an error. APIs document which condition applies. No foreign error set appears in a FOO signature.

Portable APIs specify observable behavior consistently across targets: exact byte handling, size limits, short reads, end of input, cleanup and error categories. Cryptographic APIs require secure entropy and authenticated failure behavior; an unavailable secure implementation must fail rather than substitute an insecure one.

A module's exported declarations define its detailed API. This specification fixes the language-wide contracts; it does not require mirroring another language's standard library or introduce alternate syntax for library operations.

## Standard services

| Module | Operations |
| --- | --- |
| memory | Scope allocation; explicit owners; bounded byte transfer, clearing and comparison |
| io | Standard streams, bounded reads, line reads, writes, display and close |
| fs | Open, read and write files; create a directory; join paths |
| net | TCP connect, listen, accept, port, send, receive and close |
| process | Run a shell command; count/read arguments; read environment variables |
| thread | Spawn a function, wait for completion, mutexes and conditions |
| time | Monotonic nanoseconds, sleep and measure a function's duration |
| text | Concatenate, trim, split, byte length and copied byte ranges |
| sequence | Typed creation, append, removal, copying, sorting, searching, filtering and mapping |
| log | Message and error output |
| map, set, queue, stack | Typed key/value lookup, unique values, FIFO and LIFO collections |

Use `foo doc memory`, `foo doc sequence`, or `foo doc file.iv` to read public declarations. Documentation contains signatures and public types, not function bodies or private declarations.

Sentence calls use the same exported functions as parenthesized calls. Imports and aliases apply normally:

```foo
use memory.
use io as io.
start() {
  constant destination is try allocate 4.
  try copy "FOO!" into destination.
  clear destination.
  try io.display "Ready" plus newline.
}
```

Byte transfer rejects a short destination before writing anything and permits overlapping source and destination. `compare` returns -1, 0 or 1 using unsigned byte order. The allocator-based `memory.copy(owner, pointer, content)` also remains available for explicitly owned raw allocations; sentence copying accepts bounded sequences instead.

File modes are `"read"`, `"write"` and `"append"`. `read` returns up to the requested byte count; an empty result signals end of input. `line` removes the trailing line ending. `fs.read` reads a whole file. A missing file fails. `directory` accepts an existing directory, but fails for an existing non-directory. Joining paths does not access the filesystem. An absolute right path replaces the left path.

Network operations are blocking TCP operations. Port zero asks the operating system to choose a port; `port` returns it. `send` completes the entire byte sequence or fails; `receive` may return fewer bytes than requested and returns empty at end of input. Closing a connection while another operation uses it requires caller synchronization.

`process.run` invokes the host's command shell and returns its exit status; command text follows that shell's syntax. Argument zero names the executable. An absent environment variable fails with `MissingValue`. Windows paths and environment access currently follow the process's native character encoding.

`thread.spawn` accepts a function value taking no arguments and giving nothing. Capturing closures are not supported. `wait` joins the task once; repeat waits fail with `Closed`. Protect shared mutation with a mutex. `pause(condition, mutex)` atomically releases a held mutex, waits, then reacquires it. Check the condition predicate in a loop because wakeups may be spurious. `signal` wakes one waiter. Close mutexes and conditions only after all users have finished. Outstanding tasks are joined when the program exits.

`time.current` is a monotonic timestamp in nanoseconds with an unspecified origin; subtract timestamps to measure elapsed time. Sleep accepts nanoseconds and may last longer than requested. `measure` runs a function once and returns elapsed nanoseconds. Logging writes `INFO` or `ERROR`, the message, and a newline to the diagnostic stream.

## Collection values

Sequence edits and collection edits return independently owned backing storage. They leave the original unchanged. Element values are copied shallowly: pointers and nested collections retain their existing ownership. Release each returned backing allocation once, after all aliases stop using it. Releasing a container does not release its elements. An empty collection needs no allocation. Unreleased backing storage is reclaimed at program exit.

Maps and sets preserve insertion order and use linear equality searches. Updating an existing key preserves its position. Missing map keys fail with `MissingKey`. Queue `first` and stack `top` fail with `EmptyCollection`; removal from an empty collection fails. These collections prioritize predictable behavior over asymptotic performance. Edits copy O(n) elements.

`sort[T]` requires `where T is Ord`, returns a stable sorted copy, and uses O(n²) comparisons in the worst case. `find[T]` requires `where T is Equatable` and returns an optional zero-based index. Map keys and set elements require `Equatable`. Records can derive `Equatable` when all their fields support equality; equality compares fields and sequence contents, not storage addresses. Derived `Ord` compares fields in declaration order; sequences compare lexicographically and an absent optional precedes a present value. `filter` and `map` accept ordinary function values; captured environments are not supported.

Text indexing and `length` count bytes, not characters. `trim` removes ASCII whitespace. `split` preserves empty fields, copies each field, and rejects an empty separator. Release each copied field with `text.release`, then the result sequence with `sequence.release`. Owned text returned by io, fs, net, process and text uses `text.release`. The v0 byte-oriented service interfaces also transport arbitrary bytes through the existing text representation; callers must validate untrusted bytes with `unicode.valid` before treating them as UTF-8. Byte ranges can split a multibyte character.
