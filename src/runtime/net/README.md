# Network runtime

`lib/net.iv` owns the public connection API and opaque lifetime. `tcp.c`
owns hosted TCP, while `wasi.c` owns the unthreaded WASI host bridge for its
qualified subset. `tls.c`, `discovery.c` and `datagram.c` group the other
network operations; `hosted.c` supplies shared socket helpers and includes
them in dependency order. The QBE driver stages these fragments when building
the service translation unit. Resource registration remains in
`src/runtime/provider/hosted.c`.

These files are first-party C adapters using the `FooResult` ABI and error
codes. Build them in the order selected by the QBE driver.

| Target | TCP status | Evidence or gap |
| --- | --- | --- |
| Windows x64 hosted | Host C parity passed | `node test/runtime/tcp.mjs` checks bytes, errors and cleanup; `test/library/socket.iv` exercises the QBE route. |
| Windows ARM64 hosted | Open | Target SDK and execution evidence required. |
| Linux glibc x64/ARM64 | Open here | Same hosted adapter; target execution required. |
| Linux musl x64/ARM64 | Conditional | Target runtime and network execution require qualification. |
| macOS x64/ARM64 | Open | Apple SDK and execution evidence required. |
| WASI unthreaded | Host bridge only | Direct WASI imports cover selected low-level operations; high-level network service remains unqualified. |
| WASI threads | Unsupported | Driver rejects the host socket bridge with threads. |
| Freestanding targets | Unsupported | No socket host contract. |

`test/runtime/tcp.mjs` is the hosted regression entry. No target is promoted
by source inspection alone.
