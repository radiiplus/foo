# Memory

Version: 1.

Every storage-backed value has an owner and a lifetime. Safe code cannot retain
a pointer, sequence, callback argument or resource view beyond that lifetime.
Aliasing does not extend ownership. References contained inside records and
choices obey the same rule as direct pointers.

## Scope allocation

Every function and lexical block has a scope arena. The current scope owns
allocations made without an explicit allocator:

```iv
function sample() of type fallible nothing {
  constant data is try allocate 1024.
  after { inspect(data). }
  give nothing.
}
```

The allocation operand is a byte count. Its result is
`fallible sequence of byte`, zero-filled on success. A negative count is a
type error when constant and a recoverable size error otherwise. An allocation
of zero bytes succeeds with an empty sequence and provides no dereferenceable
element. Failure leaves existing allocations unchanged.

`constant data is allocate 1024.` binds the fallible result itself; it does not
silently handle failure. Use try or catch before accessing its successful value.
A computed count uses parentheses: `allocate (count times 8)`.

Scope storage is reclaimed after its deferred cleanup. Returning it, storing it
in an outer scope, or passing it to an operation that retains it is an error.
Allocation is never silently promoted to a longer-lived arena. A nested scope
may borrow outer storage because the outer lifetime contains the inner one.

## Managed allocation

System capability permits explicit Allocator values:

```iv
use memory.

function load(owner of type Allocator) of type fallible sequence of byte {
  give try allocate 1024 using owner.
}
```

The owner operand names an Allocator value; a computed owner uses parentheses.
Allocator supplies allocate, resize, release and close contracts. Those are
capabilities of the value, not separate source pointer types.
An allocator must define whether an allocation can be released individually.
Closing an owner invalidates all its storage and borrowed views.

Allocation returns zeroed bytes. Successful resize preserves the retained
prefix, zeroes growth and invalidates old views. Failed resize preserves the old
allocation and its views. Release requires the original allocation and owner.
The type/lifetime contract of a function records which allocator or argument
owns each returned view. A public function cannot leave that relationship
ambiguous. A caller may not close an owner while a live result borrows it.

Scope exit releases a scope-owned allocator only after all dependent views,
cleanup operations and scoped tasks are finished. A process-owned allocator
cannot be closed by application code. Explicitly managed values require system
capability; ordinary allocations using the current arena require only base.

## Raw access

Unsafe blocks and native blocks allow raw addresses, pointer arithmetic,
alignment control and explicit lifetime assertions at system level. Instructions
or registers require machine level; device memory and interrupts require
hardware level. Privilege is determined by the operation, not merely by spelling
a block.

Raw access does not disable type checking for unrelated code. Its contract must
state accessed storage, aliasing, alignment, writes, synchronization and retained
references. A safe wrapper may expose a validated value or bounded view, but not
an unchecked address masquerading as a safe one.

## Escape and cleanup rules

A borrow may flow only to a lifetime contained by its owner. Calls that may
retain an argument require a longer-lived explicit owner. Unknown native calls
are assumed to retain pointer arguments unless their verified contract says
otherwise. Public lifetime relationships must be expressible at the call site.

Each normal return, propagated error, break and continue runs the registered
cleanup of every scope being exited, in reverse registration order. Cleanup
runs before arena reclamation. A cleanup block cannot return, break, continue
or propagate a new error. It may catch errors locally.

Panic terminates execution; cleanup is not guaranteed after panic or forced
process termination. Explicit close/release remains invalid while a safe borrow
is live. Concurrent accesses additionally obey [concurrency](concurrency.md).
