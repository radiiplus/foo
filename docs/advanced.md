# Advanced

Some code can run while the program is being built. `eval { ... }` must give the same answer from the same inputs: it cannot quietly read the clock or a file. A record made this way is ready before the program starts. Reflection can tell you about a type without showing compiler internals.

Custom allocators follow one simple promise: they explain how space is obtained, returned, lined up, owned, and failed. The compiler checks that promise as values move between blocks.

With `machine` or `hardware` permission, programs can update shared numbers safely, set individual bits, use processor registers, call the operating system, process many numbers at once, handle interrupts, and read device memory. Keep assembly inside native blocks.

## Compile-time values

Use `eval` when a value can be calculated once during the build:

```iv
constant buffer_size is eval { 1024 times 4 }.
```

The result is placed in the program. The calculation cannot quietly depend on a changing clock, a random number, or an undeclared file.

## Custom memory

An allocator is useful for a server pool, an embedded buffer, or a region that must be released all at once. It must answer four simple questions: who gives the space, who returns it, how must it be lined up, and what happens when there is no space? If those answers are missing, FOO rejects the allocator use.

## Bare metal

A freestanding program has no operating system to provide a file, a clock, or a process. It supplies a start function, chooses its memory, and talks to hardware through checked device operations or native code. Keep the hardware part small; put calculations and data handling in ordinary FOO where possible.

## A safe order for advanced work

First write and test the ordinary FOO version. Then measure what is too slow or unavailable. Add a library operation if one exists. Only then add a native block or machine sentence. Keep a portable version when another computer may need to run the program.

This order gives the reader a clear fallback and gives the compiler a clear boundary. It also makes a hardware bug easier to find: the ordinary version provides a result to compare with the device version.
