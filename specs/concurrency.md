# Concurrency
Version: 1.

FOO has one function model. There are no `async`, `await` or source-level spawn keywords. Tasks, channels, threads and atomics are library operations requiring the system capability. Their public interfaces use ordinary FOO types.

## Scopes
A task belongs to an explicit task scope. Leaving that scope joins every child before releasing storage that the children may borrow. This ordering applies to normal return, loop exit and propagated errors. Cancellation requests that children stop; it does not detach them or prove that they have stopped.

A child may borrow its scope's storage while the scope remains alive. A child that outlives that scope must own its data or use a longer-lived allocator. Unprovable lifetimes are rejected; dynamic checks supplement, rather than replace, the static rules.

Task failures remain fallible results. Joining reports failures through the single Error model. When several children fail, their creation order determines which failure propagates; all children are still joined. A failure already leaving the parent keeps precedence over child failures encountered during cleanup.

## Synchronization
Ordinary concurrent conflicting accesses without synchronization are invalid. Channels transfer values under their ownership contract and establish a happens-before relation between a successful send and its matching receive. Closing a channel prevents new sends; buffered values remain receivable before the closed result.

Atomic ordering values are `relaxed`, `acquire`, `release`, `both` and `sequential`. Loads permit relaxed, acquire and sequential; stores permit relaxed, release and sequential. Read-modify-write operations permit all five. Compare-exchange failure ordering cannot include release and cannot exceed the success ordering. Sequential operations participate in a single order consistent with happens-before.

Join completion happens after the child's operations. Thread creation publishes the values passed to the child. These rules apply independently of the target's instruction set.

## Execution
Task execution may suspend and resume without changing a function's type. Blocking a task waits for its result; implementations must preserve scope ownership, cancellation and error behavior across executor choices. Task networking exposes semantic connections and byte streams, not operating-system event handles.

Thread naming, affinity and pools are system services with explicit failure on unsupported targets. No scheduler throughput, fairness or lock-free progress guarantee follows solely from the language syntax. A library operation states any stronger progress guarantee in its own contract.
