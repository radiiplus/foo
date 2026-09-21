# Chapter 3 — The language

## Names and bindings

FOO separates immutable and mutable bindings in the syntax:

```iv
constant title is "Daily report".
mutable total of type integer is 0.
```

`constant` communicates that the binding will not be assigned again. `mutable` permits assignment, but does not make aliases or shared memory automatically safe. The compiler still checks the type and the lifetime of the value.

## Functions

Parameters describe values using `of type`. The result follows the same sentence-like vocabulary:

```iv
function multiply(left of type integer, right of type integer) of type integer {
  give left times right.
}
```

Generic parameters appear in brackets and constraints appear in a `where` clause:

```iv
function choose[T](left of type T, right of type T) of type T
  where T is Equatable {
  when left is right { give left. }
  otherwise { give right. }
}
```

There is one function-type spelling: `function taking (A, B) giving C`. It is a type, so it can be stored, passed to another function, or used as a callback.

## Branches and loops

`when` selects a branch and `otherwise` supplies the other branch. A complete conditional expression must account for every result path. `while` repeats while its condition is true. `for each item in values` binds each element for one iteration.

```iv
function classify(value of type integer) of type text {
  when value less than 0 { give "negative". }
  otherwise when value is 0 { give "zero". }
  otherwise { give "positive". }
}
```

`break` leaves a loop and `continue` advances to the next iteration. `defer` is not a FOO keyword; use `after` for cleanup. `cleanup` and `finally` remain accepted aliases for migration, while the formatter emits `after`.

## Expressions and evaluation

Word operators make precedence readable: `plus`, `minus`, `times`, `divided by`, and `remainder` are arithmetic; `and`, `or`, and `not` are boolean; `is`, `is not`, `less than`, and `greater than` compare values. Parentheses make grouping explicit. Function arguments are evaluated before the call according to the language's left-to-right argument rule.

## Errors as values

An operation that can fail returns `fallible T`. `try` either unwraps the value or leaves the current function with the error. `catch` handles an error locally:

```iv
function load(path of type text) of type fallible text {
  give try file read path.
}

start() {
  constant text is load("report.txt") catch error {
    display error.
    give nothing.
  }.
  display text.
  give nothing.
}
```

The `Error` type is open and named. Libraries add meaningful names without creating incompatible error-set types. Cleanup that must run only while handling failure uses `after error { ... }`.
