# Syntax Guide

This page is a compact reference for the canonical forms used throughout the
book. Each FOO block is a complete example unless the text calls it a fragment.
The normative grammar lives at `specs/grammar.md` in the repository.

## Declarations

| Form | Meaning | Example |
| --- | --- | --- |
| `constant` | Binds a value that cannot be reassigned. | `constant limit is 100.` |
| `dynamic` | Binds a value that can be changed with `set`. | `dynamic count is 0.` |
| `function` | Declares a reusable operation. | `function ready giving boolean { give true. }` |
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

`equal`, `equals`, `does not equal`, `==`, and backend helpers such as
`foo_equal` are compiler/runtime spellings, not FOO source operators. Write
`is`, `is not`, or an `or equal to` ordering phrase. These internal spellings
may appear in generated IR or native diagnostics and must not be copied into
an `.iv` file.

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
`skip` starts its next iteration. Express every other loop with `while` and an
explicit `set`, `increase`, or `decrease` update.

## Functions

```foo
function add(left integer, right integer) giving integer {
  give left plus right.
}

constant total is add(20, 22).
```

Use parentheses only when a declaration has parameters or a call has
arguments. Write `function ready giving boolean` and invoke it as `ready`;
empty `()` is invalid. Parameters use `name Type`; `giving Type` states the
result. A function with no useful result may omit `giving` and reach its
closing brace. Use `give nothing.` only when it must return early.

Generic parameters use square brackets on declarations and calls. A `where`
clause may use only the compiler-recognized capabilities `Equatable`, `Hash`,
`Ord`, and `Allocator`. They are not modules or runtime values and cannot be
imported or called. `Equatable` permits `is`, `Ord` permits ordering, `Hash`
permits generated hashing, and `Allocator` accepts only the opaque allocator
type used by generic memory helpers.

Defaults and named arguments remain part of the same call grammar:

```foo
function connect(host text, port integer default 443) giving boolean {
  give true.
}

constant secure is connect("example.com").
constant local is connect(host "localhost", port 8080).
```

A binary operator after an identifier belongs to that expression. For example,
`digit(value remainder 16)` is a positional call.

## Failure and cleanup

```foo
use file as files.

function settings giving failable text {
  give files.read("settings.json") try.
}

constant content is settings fallback "{}".
```

Postfix `try` propagates a failure from the current failable function.
`fallback` handles it locally by supplying a value of the success type. `after`
registers cleanup for ordinary scope exits, including propagated failures.

## Console input and output

The console operations are intentionally available without an import:

| Operation | Meaning | Result |
| --- | --- | --- |
| `input` | Read one line from standard input | `failable text` |
| `display value.` | Write text to standard output | `nothing` |
| `report value.` | Write diagnostic text to standard error | `nothing` |

Use `io.input`, `io.output`, and `io.report` only when code needs the
stream itself. Use `io.read`, `io.line`, `io.write`, and `io.close` for explicit
stream ownership and failure handling. The bare operations are compiler-provided
console conveniences; they are not declarations that a package must import.

## Compiler-owned names

These names have language roles. Do not try to import them, declare substitutes
for them, or assume they are standard-library values.

| Name or form | Legal role in source |
| --- | --- |
| `integer`, `unsigned`, `decimal`, `boolean`, `byte`, `character`, `text`, `nothing` | Built-in types; `nothing` is also the sole unit value. |
| `Error` | Compiler-known error type used by `fail(Error.Name)`; it is not a module. |
| `Allocator` | Compiler-known opaque allocator type; allocator values come from `memory`. |
| `Equatable`, `Hash`, `Ord`, `Allocator` after `where` | Compile-time capabilities only; they are not values, functions, or modules. |
| `null` | Absence for an expected `optional T`; it has no standalone inferred type. |
| `uninitialized` | Initial storage marker requiring an explicit expected type; reading before assignment is rejected. |
| `newline` | Built-in text value containing one line feed. |
| `anything` | Catch-all `match` pattern only; it is not a value that can be passed around. |
| `unreachable` | Compiler assertion that execution cannot continue at that point. |
| `fail(error)` | Built-in constructor for a failed `failable T`; no import provides it. |
| `allocate count [using owner]` | Built-in checked allocation expression; `memory.allocate` is the explicit allocator API. |
| `start` | Optional application entry declaration selected by the project entry. |
| `test "name" { ... }` | Test-runner declaration, discovered only by `foo test`. |
| `eval { ... }` | Compile-time declaration evaluated by the compiler. |
| `reflect[T]` and `embed("path")` | Compile-time compiler operations, not module functions. |
| `input`, `display`, `report` | Automatically mapped console operations described above. |
| `log message` and `log error` | Automatically mapped logging statements; use the `log` module for explicit control. |
| `splat`, `shuffle`, `select`, `reduce` | Compiler intrinsics valid only with the documented vector argument shapes. |
| `public use "provider" function ...` | Standard-library binding declaration only. Provider names such as `fs` and `runtime.*` are compiler/runtime identifiers, not importable modules. |
| `#[repr(C)]` | Native-interface record or union layout marker. It is not a user-defined annotation. |
| `#[noinline]` | Optimizer instruction for a function whose call boundary must remain measurable or externally observable. |
| `#[start]`, `#[interrupt]`, `#[naked]`, `#[target_feature("...")]` | Hardware-target function attributes. They require the matching target and capability; ordinary applications use `start`. |
| `#[volatile]` | Hardware-only pointer-field access marker; it is not a general variable modifier. |

Names beginning with `__`, generated symbols beginning with `foo_`, IR labels
such as `equals`, `times`, or `catch`, and backend runtime helpers are never
FOO source APIs. Their appearance in generated output or a native diagnostic
does not make them callable from an `.iv` file. Source uses `is`, `multiply`,
and `fallback` respectively.

```foo
constant name is input fallback "friend".
display "Hello, " plus name.
report "The greeting was written".
```

`input` reads one line from standard input, `display` writes to standard
output, and `report` writes to standard error. Import `io` when code must pick
a stream, read a bounded amount, handle a write failure, or close an owned
stream.

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
