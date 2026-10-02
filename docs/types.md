# Types and Values

FOO checks types before a program runs. A text value cannot accidentally become
an integer, and a failable result (one that can contain either a value or an
error) cannot be ignored.

## Primitive types (basic built-in kinds of values)

| Type | Stores | Example |
| --- | --- | --- |
| `integer` | Signed whole number | `42`, `0 subtract 8` |
| `unsigned` | Nonnegative whole number | `42` |
| `decimal` | Fractional number | `3.14` |
| `boolean` | Truth value | `true`, `false` |
| `byte` | One opaque 8-bit storage value | Produced by byte and memory APIs |
| `character` | One character | `'F'` |
| `text` | Text data | `"FOO"` |
| `nothing` | No useful value | `nothing` |

The bare numeric types use 64-bit storage. Write another width only when a
layout or foreign interface requires it:

```foo
constant offset of type integer 32 is 12.
constant port of type unsigned 16 is 8080.
constant ratio of type decimal 32 is 0.75.
```

Use backticks to separate long numbers into readable groups. They do not change
the value:

```foo
constant population is 1`000`000.
constant precise is 12`345.6789.
```

Backticks group only the whole-number part, including the part before a decimal
point. The digits after the point remain unchanged. Write ``10`000.25``, not
`10_000.25` or ``10`000.2`5``. The separator must sit between digits.

## Text and characters

Double quotes create text. Single quotes create one character.

```foo
constant language is "FOO".
constant letter is 'F'.
constant lines is "first\nsecond".
```

Common escapes are `\n` for a new line, `\t` for a tab, `\\` for a backslash,
and `\"` for a double quote inside text.

## Booleans

A Boolean is exactly `true` or `false`. Numbers and text do not become Boolean
automatically.

```foo
constant enabled is true.

when enabled {
  display "Enabled".
}
```

Write the comparison you mean instead of relying on truthiness (automatically
treating a value as true or false):

```foo
constant attempts is 1.

when attempts greater than 0 {
  display "A retry occurred".
}
```

## Optional values

`optional T` means a value may contain `T` or may be `null`.

```foo
constant selected of type optional unsigned is null.

when selected is null {
  display "Nothing selected".
}
```

An optional value represents absence. It does not represent an operation
failure; use a failable value for that.

`nothing` is the unit value returned by operations with no useful result. It is
not optional absence, and `null` cannot be used as an untyped pointer.

## Failable values

`failable T` means an operation either produces `T` or reports an error.

```foo
use file as files.

constant settings is files.read("settings.json") fallback "{}".
```

Use postfix `try` to propagate the error or `fallback` to replace it. The
[Error handling](errors.md) lesson covers both forms in detail.

## Compound types

FOO builds larger types from smaller ones:

| Type form | Purpose |
| --- | --- |
| `sequence of T` | A bounded view over values of one type. |
| `optional T` | A value that may be absent. |
| `failable T` | A result that may fail. |
| `pointer to T` | A low-level memory address. |
| `vector[N, T]` | Fixed-width SIMD data (several values processed by one processor instruction). |

Records and choices define application-specific data. They are covered in
[Data and memory](memory.md).

## Domain types instead of raw numbers

Use a record when two values share a machine representation but have different
meanings. The `time` module does this with `Instant` and `Duration`:

```foo
use time as clock.

constant delay is clock.seconds(2).
clock.wait(delay) try.
```

`clock.wait` requires a `Duration`; it does not accept an unrelated raw count.
Use `nanos`, `millis`, or `seconds` at the boundary where the unit is known.
This pattern also works for identifiers, distances, and prices.

## Type mismatch example

This does not compile:

<!-- snippet: error TypeMismatch -->
```foo
constant attempts of type integer is "three".
```

`foo check` points to the text value and explains that the declared binding
needs an integer. Change the value or change the declared type; FOO will not
guess which behavior you intended.

## Try it

1. Declare one value for each primitive type in the table.
2. Add a non-default width to an integer.
3. Write a positive `when count greater than 0` condition.
4. Deliberately assign text to an integer and inspect the diagnostic.
5. Create a typed duration with `clock.millis(50)` and pass it to `clock.wait`.

Next: [Operators](operators.md).
