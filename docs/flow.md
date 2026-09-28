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

Only the first matching branch runs. `otherwise` is optional.

FOO does not have a ternary expression. When a function must choose a value,
return from each branch or update a deliberately dynamic binding.

## `match`

Use `match` when one value is compared with several patterns.

```foo
match statusCode {
  case 200 { display "OK". }
  case 404 { display "Not found". }
  case anything { display "Other response". }
}
```

`anything` is the catch-all pattern. Put specific cases before it. Choices and
finite types are checked for exhaustive handling (every possible case must be
covered).

A case may have an additional guard:

```foo
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

`repeat until` creates a counter and stops when it reaches the limit.

```foo
repeat until index reaches 3 {
  display "Step".
  advance index.
}
```

Use `advance index.` to move the named counter forward.

## `for each`

Use `for each` to visit the elements of a collection in order.

```foo
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
function root value decimal
    when value greater than or equal to 0
    giving decimal {
  give math.root(value).
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
