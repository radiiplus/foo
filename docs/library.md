# Standard library

The library is sentence-like and hides the low-level languages used to make it run. Main families include:

| Family | Operations |
| --- | --- |
| `memory` | allocate, release, copy source into destination, clear, compare |
| `io` | read from, write, display, read line |
| `file` and `fs` | open, read, write, create directory, join path |
| `net` | connect, listen, accept, send, receive |
| `process` | run command, argument, environment |
| `text` | concatenate, split, trim, length |
| `sequence` | append, remove at, sort, find, filter, map |
| `map`, `set`, `queue`, `stack` | generic collections |
| `crypto`, `compress`, `json`, `unicode` | data and security formats |
| `time`, `system`, `log` | clocks, host information, diagnostics |

Collection algorithms state constraints in the function declaration, for example `sort[T](items) where T is Ord`. Constraint violations are compile-time errors.

## A library call from start to finish

```iv
use sequence.
start() {
  constant values is sequence create().
  sequence append values with 44.
  constant first is values at 0.
  display first.
  give nothing.
}
```

`use` makes the family available, `create` makes a sequence, `append` adds one item, and `at` reads an item. The sequence owns its storage and reports a fallible error if it cannot grow.

## Picking the right family

Use `io` for the terminal, `file` for saved files, `text` for words, and `sequence` for ordered data. Use `memory` only when you truly need a byte buffer. Use `crypto` for security work instead of writing your own hash or password code.
