# Functions

A function names a reusable operation. Its parameters describe the inputs and
`giving` describes the result.

## Define and call a function

```foo
function add(left integer, right integer) giving integer {
  give left plus right.
}

constant total is add(20, 22).
```

Arguments are evaluated from left to right. Parentheses delimit the argument
list, including an empty list for a zero-argument call.

## Default and named arguments

Write `default` after a parameter type. A missing argument uses that expression
at the call site. Defaults may refer to earlier parameters.

```foo
function connect(
    host text,
    port integer default 443,
    timeout integer default 5000
) giving boolean {
  give true.
}

constant ordinary is connect("example.com").
constant local is connect("localhost", port 8080).
constant explicit is connect(host "example.com", timeout 10000).
```

A label is the parameter name followed directly by its value. FOO does not
require a colon or equals sign. Positional arguments must come first. Each
label may appear once, and an unknown label is a compile error.

## Variadic parameters (one parameter accepting several arguments)

Use `are sequence of` on the final parameter when it should consume the
remaining arguments:

```foo
function total(values are sequence of integer) giving integer {
  dynamic result is 0.
  for each value in values {
    increase result by value.
  }
  give result.
}

constant answer is total(10, 20, 30, 40).
```

Inside the function, `values` is a read-only sequence. A variadic parameter
must be last and cannot also have a default.

## Returning a value

`give` immediately returns from the current function.

```foo
function larger(left integer, right integer) giving integer {
  when left greater than right { give left. }
  give right.
}
```

Every reachable path of a value-returning function must return the declared
type.

## Functions that return nothing

Omit `giving` when no useful value is returned.

```foo
function announce(message text) {
  display message.
}

announce("Ready").
```

Reaching the closing brace completes automatically. For an early return from a
function with no useful result, write `give nothing.`.

## Parameters and local values

Parameters are immutable bindings. Create a dynamic local when an algorithm
needs a changing value.

```foo
function sum(limit integer) giving integer {
  dynamic total is 0.
  dynamic current is 1.
  while current less than or equal to limit {
    increase total by current.
    increase current by 1.
  }
  give total.
}
```

## Public functions

Declarations are private to their file unless they begin with `public`.

```foo
public function area(width decimal, height decimal) giving decimal {
  give width multiply height.
}
```

Write explicit parameter and result types for a public API. They become the
contract seen by importing modules and packages.

## Generic functions (functions that work with several types)

Square brackets introduce type parameters.

```foo
function choose[T](left T, right T) giving T {
  give left.
}
```

A constraint states what the implementation needs:

```foo
function maximum[T](left T, right T) giving T where T is Ord {
  when left greater than right { give left. }
  give right.
}
```

Current standard constraints include `Equatable`, `Hash`, `Ord`, and
`Allocator`.

## Function values

Non-capturing functions can be passed to higher-order operations such as
`sequence.map` and `sequence.filter`.

```foo
function double(value integer) giving integer {
  give value multiply 2.
}
```

## Scoped captured closures (local functions that remember nearby values)

A local closure captures lexical values (names visible in the surrounding
code) automatically. Captured `constant`
values are read-only; captured `dynamic` values share the original storage.

```foo
function twice() giving integer {
  dynamic count is 0.

  constant next is function giving integer {
    increase count by 1.
    give count.
  }.

  constant first is next().
  give next().
}
```

Closures are scoped in this release. Call them inside the function that owns
their captured values. Returning a closure or passing it somewhere that may
retain it is rejected, preventing a reference to expired stack storage. Use
`using (name, other)` after the closure result type when an API review
benefits from an explicit capture list.

## Overloads (one function name with several parameter forms)

Functions may share a name when their parameter types or calling forms differ:

```foo
function identify(value integer) giving text {
  give "number".
}

function identify(value text) giving text {
  give "text".
}

constant kind is identify(42).
```

FOO first checks labels and arity (argument count), then chooses the most exact
compatible type match. A tie is an ambiguity error (more than one definition
matches equally well). Return type alone never selects an
overload.

## Function guards

A declaration may state a Boolean precondition (a rule that must be true before
the function runs) before `giving`:

```foo
function withdraw(amount decimal)
    when amount greater than 0
    giving decimal {
  give amount.
}
```

Arguments are evaluated before the guard. A false guard stops execution with a
`FunctionGuard` panic; it is not a recoverable `failable` error.

## Recursion (a function calling itself)

Functions may call themselves when the result type is explicit. There is no
tail-call guarantee (a promise that the final recursive call reuses the current
call's storage), so prefer an iterative loop for unbounded input.

## Preserving a call boundary

Release builds may inline small private functions. Add `#[noinline]` only when
the call itself is observable to tooling, such as a call-overhead benchmark or
a profiler boundary:

```foo
#[noinline]
function next(value unsigned) giving unsigned {
  give value plus 1.
}
```

This attribute prevents FOO-level and backend inlining. It is not a general
performance hint; ordinary application code should let the optimizer decide.

## Try it

1. Write `subtract(left integer, right integer) giving integer`.
2. Write a function with an early guard clause.
3. Write a function that returns nothing without `give nothing.`.
4. Make one function public and import it from another file.
5. Add a default parameter and call it once by name.
6. Write a scoped closure that increases a captured dynamic value.

Next: [Collections](collections.md).
