# Language Foundations

This chapter answers the questions that determine how FOO behaves beneath its
English surface. Every section labels its status. **Current** syntax is accepted
by the compiler today. **Library** behavior is supplied by the standard library
or project tools. An explicit boundary says what the language deliberately does
not promise. See [Patterns with today's language](patterns.md) for complete
examples you can compile now.

## Inference and absence

### Type inference (Current)

FOO infers a local binding from its initializer:

```foo
constant count is 42.
constant user is "Ada".
```

Function parameters, public boundaries, recursive results, empty collections,
and ambiguous numeric widths need an explicit type. Inference never changes a
value's type after declaration and never silently converts unrelated types.

### Optional values (Current)

`optional T` means that a value of type `T` may be absent. `null` is the
absence value. Absence is not failure:

```foo
constant index of type optional unsigned is null.

when index is null {
  display "Not found".
}
```

A `failable T` contains either `T` or an error. Postfix `try` propagates an
error; `fallback` supplies another success value. It does not turn an absent
optional into a value. APIs must say whether a missing result is ordinary
absence or an operational failure.

`null` can only inhabit an `optional T`; it is never a raw pointer value.
FOO has no implicit truthiness. A pointer and an optional pointer are different
types, and only the optional pointer can be `null`.

## Values and comparison

### Equality and identity (Current boundary)

`is` compares values and `is not` negates that test.
Primitive values and types deriving `Equatable` may be compared. FOO does not
expose a separate object-identity operator. Use `memory.identical[T](left,
right)` when a low-level API genuinely needs pointer identity. That check does
not prove that either pointer is live or safe to dereference.

```foo
constant left is 4.
constant right is 4.
when left is right { display "Equal". }
```

### Boolean logic (Current)

Conditions require `boolean`. `and`, `or`, and `not` use documented precedence;
parentheses make mixed conditions explicit:

```foo
constant active is true.
constant verified is false.
constant trusted is true.
when active and (verified or trusted) {
  display "Allowed".
}
```

### Operators and ordering (Current boundary)

Programs cannot declare new operators. Arithmetic remains predictable and
named functions express domain operations. Generic equality and ordering use
the `Equatable` and `Ord` constraints. This gives user-defined records checked
comparison behavior without arbitrary parser extensions.

## Generics and behavior

### Generic functions (functions that work with several types; current)

Type parameters appear in square brackets. A `where` clause constrains them:

```foo
function maximum[T](left T, right T) giving T
    where T is Ord {
  when left greater than right { give left. }
  give right.
}
```

Arguments normally infer `T`; explicit type arguments remain available when
inference has too little information. Generic records and choices use the same
bracket form.

### Capabilities and interfaces (declared abilities and shared contracts; current)

Built-in constraints describe compiler-known behavior. Application-defined
capabilities use an opaque handle (a value whose internal details are hidden)
or a record of function values. Passing that value is explicit dependency
injection (providing a required service as an argument) and makes authority
visible in the function signature. FOO does not add a parallel `T has
Capability` declaration whose method lookup, coherence (one consistent choice
of implementation),
runtime representation, and package behavior would duplicate those values.

### Iteration (Current language and library)

`for each` works with compiler-supported sequences and collection types:

```foo
use sequence.

constant items is sequence.append[text](sequence.create[text](), "value") try.
after { sequence.release[text](items) fallback nothing. }

for each item in items {
  display item.
}
```

The `iterator` module provides an explicit user-defined protocol.
`Cursor[T, S]` pairs source state with a failable pull function, while
`Step[T, S]` distinguishes an item from ordinary exhaustion with `finished`,
an optional `value`, and the next `state`. The `item` and `done` constructors
keep those fields consistent. Borrowing and cleanup remain ordinary value and
`after` rules. Custom cursors do not participate in `for each`; that loop stays
limited to compiler-supported collection values.

## Modules and visibility

### Modules (Current)

Each `.iv` file is a module. `use` imports a sibling, source-root, package, or
standard module; an alias provides a short local namespace. This fragment
uses another project module:

<!-- snippet: project account src/account.iv -->
```foo
public function active() giving boolean { give true. }
```

<!-- snippet: project account src/main.iv -->
```foo
use http as web.
use "account.iv" as account.

when account.active() { display "Active". }
```

Circular imports, unresolved modules, and colliding imported names are compile
errors. Packages are installed explicitly; the compiler does not download a
missing import during `foo run`.

### Encapsulation and re-exports (Current)

Declarations are private by default. `public` exposes a declaration from its
module. `public use module.` re-exports that module's public declarations from
a facade. Normal duplicate-name checks apply across local and re-exported
declarations. A public use cannot have an alias because exported nested
namespaces are not part of the module representation.

FOO does not have `protected`, inheritance visibility, or an `expose` alias.
Use ordinary forwarding declarations when an API needs to rename or adapt an
import rather than transparently re-export it.

## Data models

### Records and choices (Current)

Records group named fields. Choices define a closed set of variants and may
carry payloads. `match` checks finite choices for exhaustiveness.

```foo
define User as record {
  name of type text.
  age of type integer.
}.

define Status as choice {
  pending.
  active(User).
  closed.
}.
```

A generic choice gives its type arguments to its payload constructors:

```foo
define Outcome[T] as choice {
  picked(T).
  ended.
}.

constant result is picked[unsigned](42).
```

A payload-free generic variant uses the expected result type when one is
available. This keeps the common return form short:

```foo
define Outcome[T] as choice {
  picked(T).
  ended.
}.

function finish() giving Outcome[unsigned] {
  give ended.
}
```

Without an expected type, supply the type argument and call the zero-argument
constructor: `constant result is ended[unsigned]().`

When a choice comes from an aliased module, use the alias consistently in both
construction and matching: `model.picked(value)` and `case model.picked(value)`.

Fields may be initialized in declaration order or by field label. Labels are
normalized into declaration order and every field must appear exactly once:

```foo
define User as record {
  name of type text.
  age of type integer.
}.

constant user is User(age 42, name "Ada").
```

Validation constructors and computed values are ordinary functions, which can
return a failable result when validation rejects input. Structural
destructuring names the record and all of its fields, for example
`constant User(name, age) is user.` after `User` and `user` are declared.

Missing, repeated, or unknown fields are compile errors. FOO uses composition
through fields for reuse and does not provide inheritance or implicit subtype
conversion between records.

Use factory functions for validation, ordinary functions for computed values,
and explicit field bindings for destructuring. These patterns keep construction
and ownership visible without adding hidden record behavior.

### State machines (Library)

The `state` module provides `Machine[S, E]`, `create`, and `step` for an
immutable value plus an application-defined failable transition. This record
and function API is the canonical form; FOO does not add a second `state`
declaration that would hide ownership, persistence, or recovery policy.

### Serialization (turning values into storable or transferable data; current library)

The `json` module parses, inspects, streams, and writes JSON. `Codec[T]` (a
paired encoder and decoder) groups
an explicit text encoder and decoder so applications can pass a typed codec as
one value. `codec.encode[T]` and `codec.decode[T]` generate concrete JSON code
for supported scalars and records without runtime reflection. Byte buffers and
text conversions remain explicit. Applications use an explicit `Codec[T]`
when field naming, versions, unknown fields, allocation, endianness (the byte
order used to store a number), or input policy differs from that standard form.

## Memory and interoperability

### Layout (Current)

FOO supports records, packed records, explicit integer widths, pointers,
vectors, alignment operations, and byte sequences. Packed layout removes
ordinary padding but does not waive alignment (where a value may start in
memory) or bounds rules. ABI-facing layout (the binary layout used between
compiled programs) must match the declared native contract.

### Pointers and ownership (Current)

`pointer to T` is an explicit low-level address. Owned sequences and resources
must be released according to their module contract. `after` registers cleanup
for ordinary scope exits and propagated failures. FOO does not infer arbitrary
lifetimes (how long stored data remains valid) or turn pointers into
garbage-collected references.

### Unsafe and native code (Current)

`unsafe` isolates operations the checker cannot prove safe. Target-specific
code belongs behind a verified native contract, while external functions state
their ABI.
Shared-library loading lives in `dl`; operating-system APIs live in `os`.

```foo
extern "C" function add(left integer, right integer) giving integer.
```

The C ABI, system ABI, symbol spelling, calling convention, and record layout
are separate contracts. A native boundary never makes foreign memory safe.

### Panics and ordinary failures (Current)

Expected operational problems use `failable`. Failed compiler-inserted safety
checks, impossible invariants (rules that must always remain true), and
explicit unreachable paths are panics. A
panic is not catchable with `fallback`. Tests use `testing.expect`. Application
code may use `contract.require`, `contract.ensure`, and `contract.invariant`;
these functions are the canonical contract form rather than separate
language-level statements.

## Mutation and effects

### Bindings and collections (Current)

`constant` cannot be rebound. `dynamic` may be replaced with `set` or adjusted
with `increase` and `decrease`:

```foo
dynamic score is 0.
increase score by 10.
set score to score multiply 2.
```

Immutable collections return updated values. The `table` module offers an
explicit mutable text-keyed collection. A method-like phrase such as
`cart add item` has no special mutation privilege.

### Effects and permissions (Current explicit boundary)

Capabilities are values. Records containing handles and function values narrow
the operations a function receives, while pointer, borrow, move, cleanup, and
synchronization checks enforce the existing ownership boundary. Creation,
delegation, and revocation are ordinary API operations, so they remain visible
instead of being hidden in an effect annotation. FOO does not claim that every
capability record is linear or that arbitrary external effects are
deterministic.

### Transactions and failure chains (Current library boundary)

`fallback` chains can express ordered recovery:

```foo
function primary() giving failable text { give "primary". }
function secondary() giving failable text { give "secondary". }

constant offline is "offline".
constant connection is primary() fallback secondary() fallback offline.
```

The `transaction` module defines a `Participant` containing prepare, commit,
and rollback functions. `execute` registers rollback with `after error`, then
runs application work and commits. It covers one-process coordination only.
Nested transactions, irreversible side effects, cancellation, crash recovery,
and durable or distributed guarantees remain application protocols rather than
promises implied by a general-purpose block keyword.

## Concurrency (overlapping work), time, and determinism (repeatable results)

### Concurrency memory model (Current boundary)

The standard library exposes tasks, threads, channels, mutexes (locks that
allow one worker into a protected section), conditions, atomics (shared
operations completed as one indivisible step), pools, affinity (pinning work
to selected processors), and platform event backends. Shared non-atomic writes
require synchronization (coordination that prevents workers from interfering).
Atomic functions require an explicit ordering value.
The compiler does not claim automatic race detection or lock-freedom for every
operation; each module contract states stronger guarantees where available.

### Determinism (Current boundary)

Build inputs and lock files are reproducible (the same inputs produce the same
result). Runtime scheduling, clocks,
networking, process state, and random input are inherently external. There is
no `deterministic` source modifier yet. Tests that require reproducibility must
inject clocks, seeds, inputs, and services.

### Time and units (Library)

`time.current`, `time.sleep`, and `time.measure` use raw nanoseconds for
compatibility. `time.Instant`, `time.Duration`, `nanos`, `millis`, `seconds`,
`now`, `elapsed`, and `wait` provide typed monotonic time (time measured by a
clock that does not move backward) for new code.
`calendar.Date`, `Zone`, and `Moment` provide checked Gregorian dates, civil
times, and fixed UTC offsets. Named political time zones require an external
versioned database and are not guessed from an offset. `units.Quantity[D]`
keeps addition and difference operations within one dimension; constructors
provide length, mass, and temperature dimensions without unit-suffixed literals.

## Projects, tests, and compile time

### Dependencies and builds (Current)

`foo add name` and `foo add name@version` install registry packages. URLs and
paths add external dependencies. `foo.lock` records exact resolution. The
project manifest (the project's configuration record) defines the default
entry, named entries, target, backend,
optimization, native requirements, tests, and benchmarks.

`platformDependencies` selects dependencies for a matching platform, while
`optionalDependencies` may be omitted when no compatible release exists.
Build configuration remains structured JSON rather than executable source so
package resolution can occur before compilation.

### Tests and benchmarks (Current tooling)

Files under `test/` and `benchmark/` are isolated executable scenarios. Run all
or one exact file:

```sh
foo test
foo test test/account.iv
foo benchmark
foo benchmark benchmark/lookup.iv
```

Native `test "name"` blocks are current and each block runs in isolation.
`testing.every(count, property)` checks a bounded deterministic property using
indexes from zero through `count subtract 1`. `testing.Generator[T]` and
`testing.generate` map those indexes to typed generated values. Compile-time checks can use
supported `eval` computations and ordinary compiler errors; `verify at compile
time` is not accepted syntax.

### Documentation and reflection (Current boundary)

Source comments feed the published API index and editor tooling. `reflect[T]()`
provides immutable type information and `eval` performs supported compile-time
work. Checked build tasks may generate ordinary FOO source before compilation.
FOO does not provide syntax macros, compiler plugins, or a `describe` block;
generated source passes through the same parser and checker as handwritten
source.

Reflection must not bypass privacy, fabricate invalid values, or make builds
depend on unstable declaration order.

## Direction

FOO favors a small precise core over unrelated English phrases. A proposal
becomes current only when its parser, type rules, ownership behavior, backend
lowering, diagnostics, formatter, LSP, tests, and documentation ship together.
State machines, dimensional values, explicit capabilities, iterator cursors,
transactions, typed serialization, and checked source generation use the
ordinary records, functions, and project tools described above. New syntax is
added only when those forms cannot express a required safety contract.

Next: [Patterns with today's language](patterns.md).
