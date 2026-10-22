# The Language

This chapter takes a first FOO program through values, decisions, and loops.
Put each complete example in `src/main.iv`, then check and run it from the
project directory:

```sh
foo check
foo run
```

FOO uses words for many operations, but every statement has a fixed grammar
and every value has a checked type. The exact language rules are in the
[grammar](../specs/grammar.md) and [type](../specs/types.md) specifications.
The [current feature status](status.md) distinguishes implemented features
from the full specification.

## Statements and program entry

A statement ends with a dot. A block groups statements between braces; the
closing brace does not take a dot.

```foo
constant signed is true.

when signed {
  display "Welcome back".
}
```

Top-level statements form a program without a wrapper function. Use `start`
when an explicit entry is clearer. Reaching its closing brace completes it;
`give nothing.` is unnecessary.

```foo
start {
  display "Service started".
}
```

`display` writes to standard output without adding a newline. It writes text
as-is and uses the standard codec representation for supported other values.
`report` writes diagnostic text to standard error. `input` reads one line from
standard input and can fail:

```foo
constant name is input fallback "friend".
display "Hello, " plus name.
report "Greeting complete".
```

Use the `io` module when you need explicit streams, bounded reads, or write
error handling. See [Systems](systems.md) for those workflows.

Use `--` for a line comment and paired `---` delimiters for a block comment.
Block comments do not nest.

```foo
-- This line explains the next action.
---
This note can span several lines.
---
display "Visible".
```

## Bindings and scope

`constant` gives an immutable binding a name. `dynamic` declares a binding
that can change with `set`:

```foo
constant application is "Ledger".
dynamic attempts is 0.
set attempts to attempts plus 1.
increase attempts by 1.
```

`increase` and `decrease` perform the same checked arithmetic as `plus` and
`subtract` before storing the result. They require a `dynamic` target. Use a
constant unless the binding must change.

The compiler normally infers a binding's type from its initializer. Write
`of type` when the exact representation matters:

```foo
constant port of type unsigned 16 is 8080.
dynamic balance of type decimal 32 is 12.50.
```

An initializer must fit the declared type. FOO does not silently convert
unrelated values. `is` introduces one value; `are` can make a sequence-valued
binding read naturally. Both remain fully type-checked:

```foo
use sequence as items.

constant current is "Ada".
constant active is items.create[text].
constant users are active.
```

A binding is visible after its declaration. An inner block may shadow an
outer name, but two declarations in the same scope cannot share a name:

```foo
constant message is "Outside".
when true {
  constant message is "Inside".
  display message.
}
display message.
```

That example writes `InsideOutside`. A file-level value initializer must be
compile-time evaluable; a local constant does not have that restriction.
Names are case-sensitive. The project naming convention uses one clear word
for each filename, function, type, and value name. Prefer `limit` or `duration`
over constructed joins such as `retry_limit` or `retryLimit`. Type names use
one capitalized word such as `User` or `Storage`. The lexer accepts
underscores; this is a naming convention, not a different grammar.

Use `define ... as ...` when a domain value deserves a name:

```foo
define Identity as unsigned.
constant owner of type Identity is 42.
```

## Values and types

FOO infers a local binding's type from its initializer. Function parameters,
public results, recursive results, empty collections, and numeric values whose
width is ambiguous need an explicit type. A binding does not change type after
declaration. See the [type rules](../specs/types.md) for permitted numeric
conversions and expected-type inference.

| Type | Meaning | Example |
| --- | --- | --- |
| `integer` | Signed whole number | `0 subtract 8` |
| `unsigned` | Nonnegative whole number | `42` |
| `decimal` | Fractional number | `3.14` |
| `boolean` | `true` or `false` | `true` |
| `byte` | Opaque eight-bit storage value | Byte and memory APIs |
| `character` | One character | `'F'` |
| `text` | Text | `"FOO"` |
| `nothing` | No useful result value | `nothing` |

The bare numeric types use 64-bit storage. A width such as `integer 32`,
`unsigned 16`, or `decimal 32` matters for a layout or native interface.
Backticks may group digits in the whole-number part of a numeric literal:
``1`000`000`` and ``12`345.6789`` have the same values as their ungrouped
forms. Underscores are not numeric separators, and backticks cannot group
digits after the decimal point.

Double quotes create text; single quotes create a character. Text supports
escapes such as `\n`, `\t`, `\\`, and `\"`. `lengthof(value)` reads the
length of text, a sequence, an array, or a vector. Iterating text with
`for each` visits its bytes.

Booleans do not use numeric or text truthiness. Compare the value you mean:

```foo
constant attempts is 1.
when attempts greater than 0 {
  display "A retry occurred".
}
```

`optional T` holds a value of type `T` or `null`. Absence is different from
failure, which uses `failable T`. `nothing` is the unit value, not optional
absence. `null` needs an expected optional type:

A pointer is non-null; `optional pointer to T` can be absent. Neither a pointer
nor a number is implicitly treated as a Boolean condition.

```foo
constant selected of type optional unsigned is null.
when selected is null {
  display "Nothing selected".
}
```

A failable call must be handled with postfix `try` or `fallback`:

```foo
use file as files.
constant settings is files.read("settings.json") fallback "{}".
```

The [function guide](functions.md#handling-failure) covers propagation and cleanup. A
`sequence of T` is a bounded view of typed values; records and choices model
application data. See [Collections](collections.md) and [Data and memory](memory.md)
for construction and ownership. `pointer to T` and `vector[N, T]` serve
low-level and fixed-width data needs.

For domain values with units, prefer a typed library value over a raw number:

```foo
use time as clock.
constant delay is clock.seconds(2).
clock.wait(delay) try.
```

FOO rejects a declared type that conflicts with its initializer:

<!-- snippet: error TypeMismatch -->
```foo
constant attempts of type integer is "three".
```

`foo check` identifies the mismatch. Change the value or declared type;
the compiler cannot infer which behavior you intended.

## Operators

| Operation | FOO form | Example result |
| --- | --- | --- |
| Addition | `plus` | `8 plus 2` gives `10` |
| Subtraction | `subtract` | `8 subtract 2` gives `6` |
| Multiplication | `multiply` | `8 multiply 2` gives `16` |
| Division | `divide` | `8 divide 2` gives `4` |
| Remainder | `remainder` | `8 remainder 3` gives `2` |
| Equality | `is`, `is not` | `4 is 4` is `true` |
| Ordering | `greater than`, `less than` | `5 greater than 4` is `true` |
| Boolean logic | `not`, `and`, `or` | `true and false` is `false` |

Ordering also has `greater than or equal to` and `less than or equal to`.
Equality requires compatible values; FOO does not automatically convert
unrelated types.
`is` compares values, including records that derive `Equatable`. For pointer
identity at a native boundary, use `memory.identical[T]`; matching pointers
alone do not prove that their storage remains live. Programs cannot define new
operators; use named functions for domain operations.

Parentheses bind first. Then come multiplication, division, and remainder;
addition and subtraction; comparisons; `not`; `and`; `or`; and `fallback`,
in that order. Parenthesize mixed conditions when the grouping matters:

```foo
constant first is 2 plus 3 multiply 4.    -- 14
constant second is (2 plus 3) multiply 4. -- 20
```

Arithmetic alone does not update a binding. Use `set`, `increase`, or
`decrease` on a `dynamic` binding. Checked arithmetic still applies.

## Decisions and loops

Use `when` for a Boolean condition. Only the first matching branch runs.
`otherwise when` can add conditions; a final `otherwise` is optional and must
be last. `when` is a statement, not a ternary expression.

```foo
constant temperature is 24.
when temperature greater than 30 { display "Hot". }
otherwise when temperature less than 15 { display "Cold". }
otherwise { display "Comfortable". }
```

Use `match` when one value has several patterns. An `anything` arm handles
the remaining values and belongs last. Finite choices and Booleans must have
exhaustive cases. A case may add a `when` guard:

```foo
constant level of type integer is 10.
constant active is true.
match level {
  case 10 when active { display "Active administrator". }
  case 10 { display "Inactive administrator". }
  case anything { display "Member". }
}
```

Choices also support payload bindings and guarded cases:

```foo
define Result as choice {
  success(integer).
  failure(text).
  empty.
}.

constant result of type Result is success(1).
match result {
  case success(value) when value greater than 0 { display "Success". }
  case failure(reason) { display reason. }
  case anything { display "Empty". }
}
```

The compiler checks finite matches for exhaustiveness and unreachable cases.

`while` repeats while its condition is true. A dynamic counter makes a
counted loop explicit:

```foo
dynamic index is 0.
while index less than 3 {
  display "Step".
  increase index by 1.
}
```

That block runs with `index` equal to `0`, `1`, and `2`. FOO has no separate
infinite-loop keyword; write a Boolean `while` condition and make its exit
clear.

Use `for each` for a collection. Its item binding belongs to the loop body;
the collection defines iteration order, so an unordered hash map does not
promise insertion order:

```foo
use sequence as items.
function process(item integer) {}

constant values is items.create[integer].
after { items.release[integer](values) fallback nothing. }
for each item in values {
  process(item).
}
```

`skip` proceeds to the next iteration and `stop` leaves the loop. Both affect
the innermost loop:

```foo
dynamic value is 0.
while value less than 10 {
  increase value by 1.
  when value is 2 { skip. }
  when value is 5 { stop. }
  display "Kept".
}
```

An early `give` is useful for a function guard clause. A declared function
guard instead represents a fatal contract failure when false; use a failable
result when invalid input is expected. See [Functions](functions.md) and the
[error contract](../specs/errors.md).

## Try it

1. Declare a constant and a dynamic counter. Change only the dynamic one.
2. Group a large numeric literal with backticks and compare it with the
   ungrouped value.
3. Match a status code, including an `anything` arm.
4. Add `skip` and `stop` to a loop and predict what it displays.
5. Deliberately remove a statement dot, run `foo check`, and restore it.

Common errors: `expected '.'` usually means the preceding statement lacks its
terminator; `unexpected token '}'` often points to the same cause. If a
failable call is rejected, handle it with `try` or `fallback`. If
`project.ivc` is missing, run the command from the project directory.

Continue with [Functions](functions.md). Use the [quick reference](reference.md)
for commands and [Syntax Guide](syntax.md) for a compact lookup.
