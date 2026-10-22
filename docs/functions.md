# Functions

When the same calculation appears twice, give it a name. A function takes
inputs through parameters and returns a result with `give`. FOO can infer the
result type, or you can state it with `giving`.

## Define and call a function

```foo
function add(left integer, right integer) {
  give left plus right.
}

constant total is add(20, 22).
```

The compiler infers `integer` from the value given by `add`. Keep parameter
types explicit so callers know what to pass.

Arguments are evaluated from left to right. Parentheses delimit a non-empty
argument list. Omit them when a function has no parameters or arguments:

```foo
function ready giving boolean { give true. }
constant available is ready.
```

Bare zero-argument names invoke by default. When the expected type is a
function, the same name is preserved as a function value, so callbacks remain
composable. Empty `()` is not accepted.

## Sentence-call shorthand

Parenthesized calls are the form printed by `foo fmt`. When argument
boundaries are unambiguous, a call can also read as a sentence:

```foo
function add(left integer, right integer) giving integer {
  give left plus right.
}

constant result is add 10 20.
```

The values follow declaration order. Parameter labels can make a longer call
clearer; write each label directly before its value, without a colon or equals
sign. Positional values come before labeled values. Use parentheses for nested
calls and when an operator should apply to the call result. Library sentence
forms may require linking words such as `with` or `from`; the
[grammar specification](../specs/grammar.md) lists their exact forms.

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
constant sentence is connect "example.com" timeout 10000.
constant labeled is connect host "example.com" port 443 timeout 5000.
```

A label is the parameter name followed directly by its value. FOO does not
require a colon or equals sign. Positional arguments must come first. Each
label may appear once; unknown, repeated, or ambiguous labels are compile
errors. An ordinary expression may begin with a parameter named `value`; for
example,
`digit(value remainder 16)` is one positional argument, not a named argument.

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

These names are compiler-recognized capabilities, not modules, interfaces, or
runtime values. Do not `use` them or call them. `Equatable` permits `is` and
`is not`, `Hash` adds equality-consistent hashing, `Ord` permits ordering, and
`Allocator` permits allocator-dependent generic work. Application code cannot
declare new constraint kinds in language version 1.

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
function twice giving integer {
  dynamic count is 0.

  constant next is function giving integer {
    increase count by 1.
    give count.
  }.

  constant first is next.
  give next.
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

## Handling failure

Use `giving failable T` when a function can return either a value of type `T`
or an error. Postfix `try` passes a failure to the caller while continuing with
the success value:

```foo
use file as files.

function copy giving failable text {
  constant content is files.read("notes.txt") try.
  files.write("copy.txt", content) try.
  give content.
}
```

`try` applies to the failable expression immediately before it. Use
parentheses when its success value takes part in a larger expression. Repeating
`try` is meaningful only when each application unwraps another failable layer.
A non-failable function cannot propagate an error this way.

Use `fallback` when this scope has a valid replacement:

```foo
use file as files.

constant settings is files.read("settings.json") fallback "{}".
display settings.
```

The replacement has the success type of the operation and runs only on failure.
`fallback` handles the error locally; it does not propagate it. Every failable
result must be propagated with `try`, recovered with `fallback`, returned from
a compatible failable function, or consumed by an API that accepts it.
`failable nothing` can still report failure; plain `nothing` cannot.

| Situation | Use |
| --- | --- |
| The caller should decide | Postfix `try` |
| A default value is genuinely valid | `fallback value` |
| Cleanup fails and ignoring that failure is intentional | `fallback nothing` |
| Failure must terminate the process | An explicit panic or top-level policy |

A fallback chosen only to silence the compiler can hide lost data or a bad
configuration. Panics are separate from failable errors and cannot be recovered
with `fallback`.

### Cleanup on scope exit

Register cleanup with `after` immediately after acquiring a resource:

```foo
use file as files.
use io as streams.

function chunk giving failable text {
  constant stream is files.open("data.txt", "read") try.
  after { streams.close(stream) fallback nothing. }
  give streams.read(stream, 4096) try.
}
```

`after` runs when its nearest enclosing scope finishes normally, returns early,
propagates failure, or exits with `stop` or `skip`. Several cleanup blocks run
in reverse registration order. A block registered in a loop belongs to that
iteration's scope. Forced process termination cannot guarantee cleanup.

Use `after error` when an owned result must be released only if a failure
leaves the scope:

```foo
use memory.

constant allocator is memory.system.
constant buffer is memory.allocate(allocator, 4096) try.
after error { memory.release(allocator, buffer) fallback nothing. }
```

On success, ownership can transfer to the caller. `after error` does not run on
a successful `give`, `stop`, or `skip`; it runs during failure propagation and
shares the reverse cleanup order with `after`. Deferred blocks must handle
their own failures and cannot change control flow.

Low-level APIs should preserve error context across module boundaries instead
of replacing every failure with the same default. For error identity, trace,
and cleanup ordering rules, read the [error specification](../specs/errors.md).
For compiler error output, read [Diagnostics](diagnostics.md).

| Common mistake | Fix |
| --- | --- |
| Writing `is try` | Bind the expression, then put `try` after the call. |
| Ignoring a failable call | Add postfix `try` or a meaningful `fallback`. |
| Using a fallback of another type | Return the operation's success type. |
| Registering cleanup too late | Put `after` immediately after acquisition. |

## Recursion (a function calling itself)

Functions may call themselves when the result type is explicit. There is no
tail-call guarantee (a promise that the final recursive call reuses the current
call's storage), so prefer an iterative loop for unbounded input.

## Preserving a call boundary

Release builds may inline small private functions. Add `keeping call` only when
the call itself is observable to tooling, such as a call-overhead benchmark or
a profiler boundary:

```foo
function next(value unsigned) giving unsigned keeping call {
  give value plus 1.
}
```

This clause prevents FOO-level and backend inlining. It is not a general
performance hint; ordinary application code should let the optimizer decide.

## Hardware function clauses

Hardware-capability projects may describe entry and machine-level functions
with readable clauses:

| Clause | Meaning |
| --- | --- |
| `for startup` | Exports the runtime-free entry symbol that begins execution. |
| `for interrupt` | Uses the selected target's interrupt calling convention (the register and return rules used by a hardware handler). |
| `without setup` | Omits the normal function setup and cleanup so verified native instructions control the whole body. |
| `using feature "sse2"` | Allows one function to use a CPU feature already promised by the selected target profile. |

These clauses do not upgrade a project's authority or the machine it targets.
Interrupt, setup-free, and target-feature clauses require hardware capability,
and the requested operation must exist on the selected architecture. A target
feature clause cannot add a feature that the target profile did not promise.
Runtime-free code also cannot allocate memory or call file, network, process, or
other hosted services.

QBE preserves these contracts in the selected target's calling convention and
function attributes. Unsupported combinations fail during checking
or emission instead of quietly becoming ordinary functions.

```foo
function boot for startup without setup {
  native asm { "wfe" }
}

function irq for interrupt {
}
```

Older `#[...]` spellings remain accepted for source compatibility during the
migration, but formatting and new documentation use these FOO clauses.

## Try it

1. Write `subtract(left integer, right integer) giving integer`.
2. Write a function with an early guard clause.
3. Write a function that returns nothing without `give nothing.`.
4. Make one function public and import it from another file.
5. Add a default parameter and call it once by name.
6. Write a scoped closure that increases a captured dynamic value.

Next: [Collections](collections.md).
