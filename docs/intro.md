# Introduction

What does a complete FOO program look like? One line:

```foo
display "Hello, world!".
```

It prints `Hello, world!`. The period ends the statement, and the program can
run as written. You do not need to define a function or import an output
library first.

## From words to a program

FOO uses a small, precise vocabulary. `display` writes a value. `plus`
joins text or adds numbers. When you need to keep a value, give it a name:

```foo
constant name is "vibes".
display "Hello, " plus name plus "!".
```

Change `"vibes"` and run the program again. The compiler checks that the
pieces fit together before it builds the executable. You will meet functions,
types, and error handling after these first statements feel familiar.

## What FOO is for

FOO compiles through C or Zig to native code. Its sentence-like syntax is
defined grammar, rather than arbitrary English: each statement has a specific
meaning the compiler can check. The language also gives programs explicit ways
to handle failures and manage memory when they grow beyond small examples.

Those systems features matter later. To begin, you only need a project and a
file containing the first line above. [Getting Started](start.md) walks through
both, and [FOO Basics](basics.md) explains the next few statements.
