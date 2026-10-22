# Freestanding runtime

`wasm-freestanding`, `arm64-freestanding` and `riscv64-freestanding` use
`runtime: none`. Import `freestanding` for caller-owned byte operations and a
board/host callback entry point. None of these functions allocates or depends on
libc, global state or an OS import. `reserve` checks capacity and aligns an
offset relative to caller-owned storage. The caller advances its cursor to the
returned offset plus size and aligns the storage base when absolute alignment
matters. `fill`, `copy`, `move`, `identical` and `find` operate on slices
provided by the caller. `copy` requires disjoint source and destination;
`move` handles
overlap within one buffer. `copy` accepts a destination at least as large
as the source and leaves the unused tail alone. Invalid ranges in `move`
return `false` before writing. `find` returns a byte offset and finds an
empty needle at offset zero.
`joining.join` provides concatenation into a disjoint caller-owned byte
slice; its output length must exactly match the input byte lengths.
Runtime-none products require target-matched `memset`, `memcpy` and `memmove`
implementations when generated operations reference them. A final link may
replace the supplied definitions with a board-specific implementation.

Optimized byte filling can emit a `memset` reference. Link the target-matched
`src/runtime/freestanding/memory.c` object explicitly when needed; the wasm
qualification test does this and checks that the final module has no imports.

## Host callback ABI v1

The C declaration and operation/status numbers are in
`src/runtime/freestanding/host.h`. A FOO program passes a callback and its
context pointer to `freestanding.invoke`. The callback's scalar/pointer C
calling convention is the same on all three targets. A wasm application can
link a target-matched callback implementation or use a FOO callback that
accesses host-provided linear memory. The tested FOO object remains import-free;
any JavaScript imports belong to the application's final integration. A board
implements the callback against its own
devices or supervisor. Each call is synchronous. All request and response bytes
belong to the caller and may be used only until return. The context may outlive
a call. No callback may retain the request or response pointer.

A nonnegative return value is the number of bytes transferred. It must be no
greater than the response capacity for read-like operations, the data length
for write-like operations, or the specified fixed response size. Negative values
are `UNAVAILABLE` (-1), `INVALID` (-2), `IO` (-3), or `AGAIN` (-4). A callback
returns `UNAVAILABLE` for any operation it cannot provide. Buffers and handles
are byte sequences, not C structures. Integers in payloads are little-endian,
independent of native pointer width. A zero-length buffer may use a null
pointer. Handles are opaque `u32` values owned by the host and must be closed.

| Operation | Request | Response / successful return |
| --- | --- | --- |
| `QUERY` (0) | empty | 8 bytes: ABI version `u32` = 1, supported-operation bitset `u32`; return 8 |
| `CONSOLE_READ` (1) | empty | up to capacity bytes; return count |
| `CONSOLE_WRITE` (2) | bytes to write | empty; return bytes written |
| `CLOCK_MONOTONIC` (3) | empty | 8-byte nanosecond count; return 8 |
| `CLOCK_WALL` (4) | empty | 8-byte Unix nanosecond count; return 8 |
| `RANDOM` (5) | empty | up to capacity random bytes; return count |
| `FILE_OPEN` (6) | flags `u8`, then UTF-8 path bytes | 4-byte handle; return 4 |
| `FILE_READ` (7) | handle `u32`, absolute offset `u64` | up to capacity bytes; return count |
| `FILE_WRITE` (8) | handle `u32`, absolute offset `u64`, then data bytes | empty; return data bytes written |
| `FILE_CLOSE` (9) | handle `u32` | empty; return 0 |
| `NET_CONNECT` (10) | protocol `u8`, port `u16`, UTF-8 host bytes | 4-byte handle; return 4 |
| `NET_SEND` (11) | handle `u32`, then data bytes | empty; return data bytes sent |
| `NET_RECEIVE` (12) | handle `u32` | up to capacity bytes; return count |
| `NET_CLOSE` (13) | handle `u32` | empty; return 0 |
| `YIELD` (14) | empty | empty; return 0 |
| `SLEEP` (15) | duration in nanoseconds `u64` | empty; return 0 |

`QUERY` advertises support for operations 0 through 31, with bit `n` reporting
operation `n`. `FILE_OPEN` flags are read = 1, write = 2, create = 4 and
truncate = 8; unsupported combinations return `INVALID`. Network protocol 1
is TCP and 2 is UDP. The host interprets the UTF-8 host bytes, including DNS
names where it has a resolver. The host defines handle lifetime and device
availability; these are not supplied by the compiler. The callback may return
`AGAIN` for a temporarily unavailable nonblocking operation.

To qualify a board, implement the callback, validate the `QUERY` response,
then test each advertised operation against the real device or host. The QBE
tests compile this module for qualified targets and execute its pure operations
and callback dispatch in wasm; the ARM64/RISC-V boot gates execute search and
callback dispatch before serial output. A device callback implementation and
device-specific service qualification are still required for actual I/O.
