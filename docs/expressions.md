# Expressions and English Grammar

How can code read like a sentence without leaving its meaning open to guesswork?
FOO gives each expression one precise structure and a checked type. This
chapter shows the forms accepted today and calls out ideas still in design.

## Naming rule

Write every filename, function, type, and value name as one word. Let its
module and surrounding type provide context:

```foo
use file.

constant limit is 3.
constant account is "Ada".
file.read("input.txt") try.
```

Do not join several words as `retry_limit`, `retryLimit`, or `RetryLimit`.
Types use one capitalized word, such as `User` or `Storage`.

## Singular and plural bindings

Use `is` when a name represents one value and `are` when it represents several
values:

```foo
use sequence as sequences.

constant current is "Ada".
constant active is sequences.create[text].
constant user is current.
constant users are active.
```

The copula (the linking word `is` or `are`) communicates intent; the type checker still determines the exact
type from the initializer. It does not guess from whether a name ends in `s`.

## Sentence-call shorthand

Parenthesized calls are the canonical form emitted by `foo fmt`. FOO also
accepts the sentence-call shorthand in this section when the call remains
unambiguous.

The next four complete examples focus on call spelling. The shortest call
supplies values in declaration order:

```foo
function add(left integer, right integer) giving integer {
  give left plus right.
}

constant result is add 10 20.
```

Add parameter labels when they prevent ambiguity:

```foo
function connect(host text, port integer, timeout integer) giving boolean {
  give true.
}

constant socket is connect host "example.com" port 443 timeout 5000.
```

A mixed call puts positional values first:

```foo
function connect(
    host text,
    port integer default 443,
    timeout integer default 5000
) giving boolean {
  give true.
}

constant socket is connect "example.com" timeout 10000.
```

Parentheses remain available for nesting and zero-argument calls:

```foo
function tax(value integer) giving integer { give value. }
function add(left integer, right integer) giving integer { give left plus right. }
function clock giving integer { give 0. }

constant price is 20.
constant shipping is 5.
constant total is add(tax(price), shipping).
constant now is clock.
```

Labels have no colon or equals sign. Unknown, repeated, and ambiguous labels
are compile errors. A binary operator after an identifier keeps the expression
positional, so `digit(value remainder 16)` does not label its argument.

## Defaults, remaining arguments, and overloads

```foo
function connect(
    host text,
    port integer default 443,
    timeout integer default 5000
) giving boolean {
  give true.
}

function total(values are sequence of integer) giving integer {
  dynamic result is 0.
  for each value in values { increase result by value. }
  give result.
}
```

Defaults are evaluated for each call, from left to right, and may use an
earlier parameter. Only the final parameter may consume remaining arguments.
Its sequence is read-only.

An overload set (several parameter forms sharing one function name) may contain
the same function name more than once. Resolution
uses labels and argument count before comparing input types. Exact matches beat
conversions. A tie is reported as an ambiguity; result type is never used to
break it.

## Intentional mutation (changing an existing value)

Use `increase` and `decrease` when the operation updates the same dynamic
binding:

```foo
dynamic score is 0.
dynamic health is 100.
increase score by 10.
decrease health by 5.
```

Use `set` for a replacement or a more complex calculation:

```foo
dynamic price is 20.0.
constant rate is 1.5.
set price to price multiply rate.
```

Both forms retain overflow checks and reject immutable targets.

## Function guards

```foo
function withdraw(amount decimal)
    when amount greater than 0
    giving decimal {
  give amount.
}
```

The guard runs after arguments are evaluated and before the body. A false guard
is a contract panic. Expected invalid input belongs in a `failable` function
instead.

## Scoped closures

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

The closure (a local function that remembers nearby values) captures referenced
lexical bindings (names visible in the surrounding code). A captured constant remains
immutable. A captured dynamic binding refers to its original storage, so the
second call above gives `2`.

These closures are scoped: they must be called while the defining function is
active. FOO rejects returning or retaining one. This prevents dangling capture
storage until the ownership model gains an explicit heap-owned closure form.

## Current pattern matching

`match` supports literals, `anything`, choice variants, payload bindings, and
case guards:

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

The compiler checks unreachable cases and exhaustiveness (whether every
possible case is covered) for finite types.

## Design-stage syntax

The following ideas are directions, not accepted source syntax yet:

| Area | Direction being evaluated | Main question still open |
| --- | --- | --- |
| Structural patterns | Record and sequence destructuring | Rest-pattern and ownership rules |
| Partial application | `add 10 waiting` or contextual `add 10` | When a call is intentionally incomplete |
| Pipelines | `data through parse then validate` | Failure and async propagation between stages |
| Collection expressions | `each item in values ... give item` | Eager storage, allocator, and ownership |
| Lazy sequences | `sequence each item in values` | Cancellation and retained captures |
| Generators | `give next value` | Generator frame ownership and cleanup |
| Multiple results | Record destructuring rather than anonymous tuples | Stable names and ABI layout |
| Distinct types | `define Identity as distinct unsigned` | Explicit conversion vocabulary |
| Refinement types | `where value greater than 0` | Runtime checks versus compile-time proof |
| Capabilities | Values that grant file or network authority | Delegation and package boundaries |
| Resource expressions | `with ... as ...` | Interaction with existing `after` cleanup |
| Effects and contracts | `requires`, `ensures`, and `invariant` | What is statically provable |
| Compile-time conditions | `when building for Windows` | Portable target-query vocabulary |
| Parallel blocks | Structured parallel expressions | Result ordering and cancellation |
| Transactions | Coordinated commit and rollback | Resource participation protocol |
| Timeout and retry | `try within` and bounded `retry` | Time source, cancellation, and idempotence (whether repeating an operation has the same effect) |
| Reactive values | `total follows price multiply quantity` | Scheduling, lifetime, and cycle handling |
| Native queries | `where`, `order by`, and `take` | Collection versus database execution |

Do not publish a package that depends on a design-stage spelling. Track the
feature contract and changelog for the point when a proposal receives parser,
type-system, backend, diagnostic, and documentation support together.

Next: [Functions](functions.md).
