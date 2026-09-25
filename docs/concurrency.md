# Chapter 6: Concurrency

FOO provides two concurrency families. `thread` runs function-valued work on OS
threads. `task` exposes the runtime-selected task executor, integer channels,
scopes, pools, and asynchronous networking.

## Threads

`thread.spawn` accepts a function taking no arguments and giving `nothing`. It
returns a fallible thread handle, so both creation and waiting must be handled.

```foo
use thread as threads.

function worker() {
  display "Work finished".
}

constant handle is threads.spawn(worker) try.
after { threads.close[threads.Thread](handle) fallback nothing. }

display "Waiting for worker".
threads.wait(handle) try.
```

Threads also provide mutexes and conditions. Lock and unlock the same mutex,
and use `after` to guarantee that a successful lock is released.

```foo
use thread as threads.

function protectedWork(mutex pointer to threads.Mutex)
  giving fallible nothing {
  threads.lock(mutex) try.
  after { threads.unlock(mutex) fallback nothing. }
}
```

## Tasks

The task substrate records IOCP on Windows, epoll on Linux, and kqueue on
Darwin/BSD as the target reactor. Scoped work and channels currently use the
backend's native threads and atomics; network reactor operations remain the
advanced low-level surface. Its operations use explicit handles and callbacks:

```foo
use task.

constant executor is task.executor() try.
constant channel is task.channel() try.
constant scope is task.scope() try.
constant pool is task.pool() try.
```

Use `task.launch(scope, callback, argument)` for scoped work and call
`task.join(scope)` before leaving the scope. Use
`task.submit(pool, callback, argument)` followed by `task.wait(pool)` for pooled
work. Channel values are signed 64-bit integers; `task.send` and `task.receive`
return booleans so the caller can handle a closed or unavailable channel.

Backend selection is a compile-time optimization decision, not a source-level
fork. A backend must preserve the same scope, ordering, cleanup, and error
contracts even when it uses different OS primitives. New fast paths should be
kept only when benchmarks show a gain on their target and the portable path
remains the fallback.

## Atomics

The `atomic` module provides explicit memory ordering. Each operation that can
fail is handled like any other fallible FOO call.

```foo
use atomic.

constant counter is atomic.create(0) try.
after { atomic.release(counter). }
constant previous is atomic.add(counter, 1, "sequential") try.
constant current is atomic.load(counter, "sequential") try.
```

Prefer channels and scoped work when ownership must move between workers. Use
atomics only for small shared values with a deliberately chosen memory order.
