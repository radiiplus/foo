# Syntax Guide

This page is a compact reference for the canonical forms used throughout the
book. Each FOO block is a complete example unless the text calls it a fragment.
The normative grammar lives at `specs/grammar.md` in the repository.

## Declarations

| Form | Meaning | Example |
| --- | --- | --- |
| `constant` | Binds a value that cannot be reassigned. | `constant limit is 100.` |
| `dynamic` | Binds a value that can be changed with `set`. | `dynamic count is 0.` |
| `function` | Declares a reusable operation. | `function ready() giving boolean { give true. }` |
| `public` | Makes a declaration visible to importing modules. | `public constant limit is 100.` |
| `use` | Imports a module or file. | `use file.` |
| `define ... as ...` | Introduces a named type. | `define Identity as unsigned.` |

Use `is` for a singular binding and `are` when the binding represents several
values. Both forms retain ordinary static type checking.

```foo
constant title is "Report".
dynamic retries is 0.
set retries to retries plus 1.
```

## Types and values

| Type | Meaning | Example value |
| --- | --- | --- |
| `integer` | Signed 64-bit whole number. | `42` |
| `unsigned` | Unsigned 64-bit whole number. | `42` |
| `decimal` | Binary64 fractional number. | `3.14` |
| `boolean` | Exactly `true` or `false`. | `true` |
| `byte` | One opaque 8-bit storage value. | Produced by byte and memory APIs. |
| `character` | One Unicode scalar. | `'F'` |
| `text` | Immutable validated UTF-8 text. | `"hello"` |
| `nothing` | The unit type and its only value. | `nothing` |
| `optional T` | A present `T` or absent `null`. | `null` |
| `failable T` | A successful `T` or an error. | Returned by a failable call. |
| `sequence of T` | A bounded contiguous view of `T` values. | Returned by collection APIs. |
| `pointer to T` | A non-null native address with provenance. | Returned by memory APIs. |
| `vector[N, T]` | `N` fixed SIMD lanes of `T`. | Constructed by vector APIs. |

The bare numeric names are the canonical 64-bit spellings. A non-default width
may be written when representation matters, such as `integer 32`, `unsigned
16`, or `decimal 32`.

`nothing` and `null` are different. `nothing` is a real unit value; `null` is
only the absent value of an `optional T`.

## Records and choices

```foo
define User as record {
  name of type text.
  active of type boolean.
}.

define Status as choice {
  ready.
  failed(text).
}.

constant user is User("Ada", true).
constant status is ready.
```

Record fields keep `of type` because they declare stored layout. Function
parameters use `name Type`, as shown later on this page.

## Operators

| Operation | Canonical form |
| --- | --- |
| Addition | `left plus right` |
| Subtraction | `left subtract right` |
| Multiplication | `left multiply right` |
| Division | `left divide right` |
| Remainder | `left remainder right` |
| Equality | `left is right` |
| Inequality | `left is not right` |
| Ordering | `less than`, `greater than`, and their `or equal to` forms |
| Boolean logic | `not`, `and`, `or` |

Multiplication, division, and remainder bind more tightly than addition and
subtraction. Use parentheses when mixed Boolean conditions would be easier to
misread.

## Conditions

```foo
constant temperature is 24.

when temperature greater than 30 {
  display "Hot".
}
otherwise when temperature less than 15 {
  display "Cold".
}
otherwise {
  display "Comfortable".
}
```

Branches are checked in order, and only the first matching branch runs. The
final `otherwise` is optional.

Use `match` when one value is compared with several patterns:

```foo
constant status of type integer is 404.

match status {
  case 200 { display "OK". }
  case 404 { display "Not found". }
  case anything { display "Other response". }
}
```

`anything` is the catch-all pattern. A match must cover every possible value;
an integer match therefore needs an unguarded catch-all.

## Loops

```foo
dynamic index is 0.

while index less than 3 {
  set index to index plus 1.
}
```

Use `for each` for a bounded sequence. `stop` leaves the nearest loop and
`skip` starts its next iteration. FOO has no separate `repeat until`, `advance`,
or infinite-loop form.

## Functions

```foo
function add(left integer, right integer) giving integer {
  give left plus right.
}

constant total is add(20, 22).
```

Parenthesized calls are canonical. Parameters use `name Type`; `giving Type`
states the result. A function with no useful result may omit `giving` and reach
its closing brace. Use `give nothing.` only when it must return early.

Defaults and named arguments remain part of the same call grammar:

```foo
function connect(host text, port integer default 443) giving boolean {
  give true.
}

constant secure is connect("example.com").
constant local is connect(host "localhost", port 8080).
```

## Failure and cleanup

```foo
use file as files.

function settings() giving failable text {
  give files.read("settings.json") try.
}

constant content is settings() fallback "{}".
```

Postfix `try` propagates a failure from the current failable function.
`fallback` handles it locally by supplying a value of the success type. `after`
registers cleanup for ordinary scope exits, including propagated failures.

## Modules and native calls

```foo
use file as files.
extern "C" function puts(value pointer to byte) giving integer.
```

Each `.iv` file is a module. Declarations are private unless marked `public`.
`extern "C"` declares a typed C ABI boundary; the linked symbol must obey the
declared signature. Target-specific code and assembly belong behind a verified
native contract, not in an ordinary standalone assembly statement.

## Statement endings

A period ends a simple statement. Blocks use braces and do not add a period
after the closing brace. Comments begin with `--`.

```foo
-- This is one complete statement.
display "Ready".

when true {
  display "The block needs no trailing period".
}
```

Continue with [The Language](language.md) for a guided explanation or
[Reference](reference.md) for a command-oriented lookup.
