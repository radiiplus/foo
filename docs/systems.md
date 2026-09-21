# Systems programming

The standard library supplies file, process, network, clock, text, and logging operations. These APIs return ordinary FOO values and `fallible` results (a value that may contain an error). C names and operating-system handles do not appear in ordinary library documentation.

```iv
use file.

function read(path of type text) giving fallible text {
  give try file read path.
}
```

Use `native c { ... }` or `native asm { ... }` only behind an explicit binding. Native blocks are opaque to optimization, cannot be exported from a public package API, and may interact with FOO only through declared parameters and results.

```iv
native c {
  #include <stdio.h>
}

extern "C" function puts(value of type pointer to byte) giving integer.
```

`use c "header.h".` invokes the header binding pipeline. Bindings and macro hints are cached under `.artifacts`; unbindable constructs receive FOO diagnostics.

## Start at the highest level

Prefer this:

```iv
constant text is file read "notes.txt".
```

It says what the program wants and lets the library report an ordinary FOO error. Move lower only for a special operating-system feature or a measured need.

## A native boundary

Keep the boundary small and name every value crossing it:

```iv
extern "C" function checksum(data of type pointer to byte, size of type unsigned 64) of type unsigned 64.
function total(data of type pointer to byte, size of type unsigned 64) of type unsigned 64 {
  give checksum(data, size).
}
```

The rest of the program calls `total`; only its declaration knows that the implementation comes from C.
