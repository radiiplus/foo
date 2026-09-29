# Chapter 6: Concurrency

Concurrency means making progress on more than one piece of work during the
same period. FOO provides two concurrency families. `thread` runs
function-valued work on OS threads. `task` exposes the runtime-selected task
executor (the service that schedules work), integer channels (queues used by
workers to exchange values), scopes, pools, and asynchronous networking (work
that can continue while a network operation waits).

## Threads

`thread.spawn` accepts a function taking no arguments and giving `nothing`. It
returns a failable thread handle (a result that may contain an error), so both
creation and waiting must be handled.

```foo
use thread as threads.

function worker {
  display "Work finished".
}

constant handle is threads.spawn(worker) try.
after { threads.close[threads.Thread](handle) fallback nothing. }

display "Waiting for worker".
threads.wait(handle) try.
```

Threads also provide mutexes (locks that allow one worker into protected code)
and conditions. Lock and unlock the same mutex,
and use `after` to guarantee that a successful lock is released.

```foo
use thread as threads.

function protect(mutex pointer to threads.Mutex)
  giving failable nothing {
  threads.lock(mutex) try.
  after { threads.unlock(mutex) fallback nothing. }
}
```

## Tasks

The hosted C task pool dispatches callbacks (functions run after work becomes
ready) through IOCP (Windows completion events) on Windows and epoll with
`eventfd` (Linux readiness and wake-up services) on Linux. Zig, Darwin/BSD, and
other targets currently select the threaded fallback. Scoped work still uses
native threads, while pools reuse a bounded worker set (a limited number of
reusable workers). Socket readiness (whether network work can proceed) and
suspended language continuations (saved work that will resume later) are not
yet attached to these event queues. Operations use explicit handles and
callbacks:

```foo
use task as tasks.

constant executor is tasks.executor try.
constant channel is tasks.channel try.
constant scope is tasks.scope try.
constant pool is tasks.pool try.
```

Use `task.launch(scope, callback, argument)` for scoped work and call
`task.join(scope)` before leaving the scope. Use
`task.submit(pool, callback, argument)` followed by `task.wait(pool)` for pooled
work. Channel values are signed 64-bit integers; `task.send` and `task.receive`
return booleans so the caller can handle a closed or unavailable channel.

Backend selection is a compile-time optimization decision, not a source-level
fork (two different versions written by the programmer). A backend must
preserve the same scope, ordering, cleanup, and error contracts even when it
uses different OS primitives (basic services supplied by the operating
system). New fast paths should be
kept only when benchmarks show a gain on their target and the portable path
remains the fallback.

## Atomics

The `atomic` module provides explicit memory ordering (rules for when one
worker may observe another worker's changes). Each operation that can
fail is handled like any other failable FOO call.

```foo
use atomic.

constant counter is atomic.create(0) try.
after { atomic.release(counter). }
constant previous is atomic.add(counter, 1, "sequential") try.
constant current is atomic.load(counter, "sequential") try.
```

Prefer channels and scoped work when ownership must move between workers. Use
atomics only for small shared values with a deliberately chosen memory order.
