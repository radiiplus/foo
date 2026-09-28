 # Chapter 4: Data and Memory (Safe, Fast, and Automatic)

In many high-performance languages, managing memory (RAM) is a manual, error-prone nightmare. You have to remember to free every single byte you allocate, or your app will crash. 

FOO uses scoped regions (groups of memory released together), explicit
allocator values (objects that reserve and release memory), and compile-time
lifetime checks (checks of how long data may safely be used). It is not a
tracing garbage collector (a runtime that searches for unused memory):
ownership (responsibility for a resource) and cleanup remain
visible where a program asks for storage or acquires a resource.

Let’s look at how FOO stores your data.

---

## 1. Structuring Data: Records

A **Record** is FOO’s version of a `struct` or `class`. It groups related data together. 

FOO gives you three layout options depending on your needs:

### The Default `record` (Optimized for Speed)
By default, FOO gives fields the target's natural alignment (the memory
positions preferred by the processor). Field order remains
the order written in source; the compiler does not silently rearrange a public
record based on access frequency.
```foo
public define User as record {
  id of type unsigned 64.
  name of type text.
  active of type boolean.
}.
```

### The `packed` Record (Optimized for Space)
If you are talking to hardware or sending data over a network, you need every
bit to be exactly where you expect it. A `packed` record strips out padding
(unused bytes inserted to align fields) between its fields.
```foo
public define Header as packed record {
  version of type integer 4.
  flags of type integer 4.
  length of type integer 16.
}.
```

### The `c` Record (Optimized for Interoperability)
If you need to talk to a C library, FOO can match the C memory layout perfectly so you can pass data back and forth seamlessly.
```foo
#[repr(C)]
public define Point as record {
  x of type integer.
  y of type integer.
}.
```

---

## 2. The Magic of Regions (Bulk Cleanup)

In languages like C or C++, if you allocate 100 objects, you have to manually free 100 objects. If you miss one, you have a **Memory Leak**.

FOO encourages **Region-Based Memory Management** (also known as Arenas). Think of a Region as a dedicated workbench. You build everything on that bench, and when you are done, you just sweep the entire bench clean in one motion.

```foo
function process() giving failable nothing {
  -- 1. Create a temporary workspace (Region)
  constant arena is memory.arena() try.
  
  -- 2. Guarantee cleanup! This runs even if the function fails.
  after { memory.close(arena) fallback nothing. }
  
  -- 3. Allocate data INSIDE the arena
  constant buffer is memory.allocate(arena, 1024) try.
  constant image is loadImage(arena, "photo.png") try.
  
  -- Do work...
  
  -- When we reach the end, 'memory.close(arena)' frees EVERYTHING at once!
}
```

Closing a region reclaims its allocations (reserved pieces of memory) together. `after` makes that cleanup
run for normal returns, propagated failures, `stop`, and `skip`. A panic or
forced process termination does not guarantee cleanup, and foreign code can
still leak resources when its declared contract is wrong.

---

## 3. Sealing: The Invisible Safety Net

You might be wondering: *"What if I try to use the buffer after I close the arena?"*

This is where FOO's **Sealing** (checking that memory operations follow their
required order) kicks in. As the compiler builds your program, it creates a
dependency map of your memory. It tracks exactly when memory is created, used,
and destroyed.

If you try to access data after it has been sealed (closed), FOO will stop the build with a clear error:
```text
main.iv:15:10
  constant text is memory.view(arena, buffer, 16) try.
                                 ^^^^^^
  Cannot use 'buffer' after its owning region has been closed.
```

Safe FOO rejects a view that is provably used after its owner closes or escapes
to a longer lifetime (period during which data remains valid). Raw native code remains responsible for honoring the
contract it declares.

---

## 4. Ownership, Borrowing, and Movement

Every storage-backed value has an owner (the value responsible for keeping and
releasing the storage). A sequence, pointer, or resource view may borrow (use
without taking ownership of) that storage only while the owner remains alive. Returning a borrowed
value requires an ownership relationship that the caller can prove. Passing a
value to an operation that may retain it requires an explicit longer-lived
owner.

FOO v1 tracks these relationships through types, scopes, and library contracts;
there is no `borrow`, `move`, or source lifetime-annotation syntax. Assignment
of scalar values copies the value. Collection operations document whether they
return a view, shallow copy (a copy that still refers to the same inner data),
or separately owned allocation. A shallow copy of
a pointer or nested collection does not extend the underlying lifetime.

FOO v1 also has no user-defined `Copy` or `Drop` trait, reference-counted smart
pointer, or weak reference. Resource cleanup is expressed with `after`, and
custom ownership is expressed with an `Allocator` (an object that reserves and
releases memory).

---

## 5. Stack, Scope, and Heap Storage

Stack storage (short-lived memory tied to a function call) belongs to the
current function call; heap storage (memory with an explicitly managed
lifetime) can remain
after that call, while scope describes the part of the program using it.

Plain local scalars and fixed records can use ordinary local storage when they
do not escape. `allocate count` uses the current scope arena and returns a
zero-filled `failable sequence of byte`. `allocate count using owner` uses an
explicit allocator. The compiler may change physical placement when observable
ownership, layout, and lifetime behavior stays the same.

Storage is never silently promoted to a longer-lived arena. Explicit allocators
provide allocate, resize, release, and close contracts.

Alignment control, address arithmetic, and lifetime assertions require an
`unsafe` or native block at the appropriate capability level. Ordinary pointers
are non-null and provenance-aware (the compiler tracks where an address came
from); nullability is written as
`optional pointer to T`.

---

## 6. Optimized Storage Operations

Runtime copy, clearing, allocation growth, hashing, text splitting, and
collection transforms use backend-specific implementations behind one portable
contract. Release builds may select AVX2, AArch64, Zig, or portable C paths for
a compatible target. This does not change record layout or weaken bounds and
overlap checks.

Copy selection also considers size and overlap. AVX2 serves the measured medium
range, `rep movsb` is restricted to non-overlapping 1 KiB through 8 KiB machine
copies, and other C transfers retain `memmove`. Zig copies forward or backward
in target-sized blocks. Zero-length and identical-address transfers do no work.
See [Optimization Under the Hood](tuning.md) for the exact path table and
benchmark rules.

---

## Summary: The FOO Memory Philosophy

FOO combines bulk cleanup with checked lifetimes and explicit low-level escape
hatches. Safe code prevents the ownership errors it can prove; native code,
panic paths, and external resources still require deliberate contracts and
testing.

In the next chapter, we will look at **Systems**, where we will learn how to talk to files, processes, and the operating system itself!
