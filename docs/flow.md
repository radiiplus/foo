# Conditions and Loops

Control flow chooses which statements run and how often they run.

## `when`

Use `when` for a Boolean condition.

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

Only the first matching branch runs. Any number of `otherwise when` branches
may follow the first `when`. A final `otherwise` is optional, must be last, and
cannot begin a chain without a preceding `when`.

FOO does not have a ternary expression. When a function must choose a value,
return from each branch or update a deliberately dynamic binding.

## `match`

Use `match` when one value is compared with several patterns.

```foo
constant status of type integer is 404.

match status {
  case 200 { display "OK". }
  case 404 { display "Not found". }
  case anything { display "Other response". }
}
```

`anything` is the catch-all pattern and satisfies exhaustiveness. Put it last;
later cases are unreachable. Choices, Booleans, and other types whose complete
set of variants is known to the checker are finite and must be exhaustive.
Every choice variant needs one case whether or not that variant carries a
payload.

A case may have an additional guard:

```foo
constant level of type integer is 10.
constant active is true.

match level {
  case 10 when active { display "Active administrator". }
  case 10 { display "Inactive administrator". }
  case anything { display "Member". }
}
```

## `while`

`while` repeats while its condition remains true.

```foo
dynamic count is 0.

while count less than 3 {
  display "Working".
  set count to count plus 1.
}
```

Make sure something can eventually make the condition false. FOO has no
separate infinite-loop keyword.

## Counted repetition

FOO uses an ordinary dynamic value and `while` for a counted loop. The update is
visible, so the reader can see exactly when the counter changes.

```foo
dynamic index is 0.

while index less than 3 {
  display "Step".
  set index to index plus 1.
}
```

This block runs three times, with `index` equal to `0`, `1`, and `2`.

## `for each`

Use `for each` to visit the elements of a collection in order:

```foo
use sequence as items.

function process(item integer) {}

constant values is items.create[integer]().
after { items.release[integer](values) fallback nothing. }

for each item in values {
  process(item).
}
```

The item binding belongs to the loop body. The collection decides iteration
order; an unordered hash map does not promise insertion order.

## `stop` and `skip`

`stop` leaves the nearest loop. `skip` moves to its next iteration.

```foo
dynamic value is 0.

while value less than 10 {
  set value to value plus 1.
  when value is 2 { skip. }
  when value is 5 { stop. }
  display "Kept".
}
```

These words only control the innermost loop.

## Guard clauses

Return early when a condition rules out the rest of a function:

```foo
function absolute(value integer) giving integer {
  when value greater than or equal to 0 { give value. }
  give 0 subtract value.
}
```

This is often clearer than wrapping the entire function in `otherwise`.

For a reusable precondition, put a function guard between the parameters and
result declaration:

```foo
function root(value decimal)
    when value greater than or equal to 0
    giving decimal {
  give value.
}
```

The guard is checked on every call. A false guard is a fatal contract failure,
so use a `failable` result (one that may contain an error) when invalid input is
an expected runtime event.

## Try it

1. Classify a number as negative, zero, or positive with `when`.
2. Match a status code and include `anything`.
3. Count from zero to four with `while`.
4. Add `skip` for one value and `stop` for a later value.

Next: [Functions](functions.md).
