# Patterns with Today's Language

FOO deliberately keeps its core language small. Some familiar features are
therefore written as records and functions instead of special syntax. This
chapter shows the supported pattern for each case.

Every example on this page uses current FOO syntax. Application snippets belong
in `src/main.iv`; snippets beginning with `test` belong in a file under `test/`.
After adding any declarations that the focused snippet refers to, run:

```sh
foo check
foo run
```

Use `foo check` first. It reports type, ownership, and missing-name mistakes
without building an executable. Then use `foo run` for an application or
`foo test` for a test file.

## Constructors and computed values

A record constructor accepts fields in declaration order or by label. Put
validation or default selection in an ordinary function when direct
construction is too permissive.

```foo
define User as record {
  name of type text.
  age of type unsigned.
}.

function create(name text, age unsigned) giving failable User {
  when age greater than 130 {
    give fail(Error.Age).
  }
  give User(name, age).
}

function label(user User) giving text {
  give user.name.
}

constant user is create("Ada", 37) try.
constant direct is User(age 37, name "Ada").
display label(user).
```

`create` is the custom constructor. `label` is the computed value. Neither one
needs constructor or computed-field syntax. A structural destructure such as
`constant User(name, age) is direct.` names the record and every field, so
adding a field produces a compile error instead of silently changing the
binding order.

Use composition when one record contains another. This fragment reuses `User`
from the complete example above:

<!-- snippet: context -->
```foo
define Account as record {
  owner of type User.
  active of type boolean.
}.
```

FOO does not treat `Account` as a subtype (a type accepted wherever another
type is expected) of `User`. Read the contained value
as `account.owner` and pass it explicitly.

## Typed time

The `time` module supplies `Instant` and `Duration` records. Constructors name
the unit at the boundary, so a raw count is not accidentally passed as a
duration.

```foo
use time as clock.

constant delay is clock.millis(250).
constant first is clock.now() try.
clock.wait(delay) try.
constant last is clock.now() try.
constant elapsed is clock.elapsed(first, last).

when elapsed.nanoseconds greater than 0 { display "The clock advanced". }
```

Use `clock.nanos`, `clock.millis`, or `clock.seconds` to construct a duration.
`clock.elapsed` panics if the second instant is earlier because unsigned
subtraction is checked. Use `calendar.Date`, `calendar.Zone`, and
`calendar.Moment` for civil time with a fixed UTC offset. Named political time
zones require an external versioned time-zone database. An `Instant` remains a
monotonic measurement point (a clock value that does not move backward) rather
than a calendar timestamp.

## Explicit codecs

`Codec[T]` groups the two directions of a text conversion. The application
still decides field names, versions, limits, and validation.

```foo
use codec as codecs.

define Token as record {
  value of type text.
}.

function encode(token Token) giving failable text {
  give token.value.
}

function decode(source text) giving failable Token {
  when source is "" { give fail(Error.Empty). }
  give Token(source).
}

constant codec is codecs.Codec[Token](encode, decode).
constant token is codec.decode("abc") try.
constant stored is codec.encode(token) try.
display stored.
```

For the standard JSON representation of a concrete scalar or record, FOO can
generate both directions directly. This fragment reuses `codecs` and `Token`
from the complete example above:

<!-- snippet: context -->
```foo
constant stored is codecs.encode[Token](Token("abc")) try.
constant restored is codecs.decode[Token](stored) try.
```

The generated path is type-specific and does not use runtime reflection. Use an
explicit `Codec[T]` when field names, versions, validation, or the wire format
differ from the standard representation. Generated codecs currently cover
booleans, integers, decimals, text, and nested records.

## State machines

The `state` module stores a value and a transition function. `step` returns a
new machine, so the old value does not change behind the caller's back.

```foo
use state as states.

function transition(value integer, event integer) giving failable integer {
  constant next is value plus event.
  when next greater than 100 {
    give fail(Error.Transition).
  }
  give next.
}

constant machine is states.create[integer, integer](40, transition).
constant changed is states.step[integer, integer](machine, 2) try.
when changed.value is 42 { display "Transition accepted". }
```

The example prints `42`. In an application, replace the integers with closed
`choice` types for states and events. The transition function owns the rule for
legal movement. Native `state` syntax and compiler-checked concurrent
transitions do not exist yet.

## Cursor iteration

Custom types cannot participate in `for each` yet. Use a cursor with a `next`
function that returns a closed step choice.

```foo
define Step as choice {
  item(unsigned).
  done.
}.

function next(index unsigned) giving Step {
  when index less than 3 { give item(index). }
  give done.
}

dynamic index of type unsigned is 0.
dynamic running is true.
while running {
  match next(index) {
    case item(value) {
      when value less than 3 { display "Cursor item". }
      increase index by 1.
    }
    case done { set running to false. }
  }
}
```

The three parts are always visible:

1. Store the cursor position explicitly.
2. Extract an item only in the `item(value)` case.
3. Stop in the `done` case.

Add a failure variant or make `next` return `failable Step` when reading can
fail. A resource-backed cursor also needs an immediate `after` cleanup.

## Capabilities as values

A record of function values can represent authority. Code receives only the
operations it is allowed to call.

```foo
define Clock as record {
  current of type function taking () giving unsigned.
}.

function fixed() giving unsigned {
  give 42.
}

function stamp(clock Clock) giving unsigned {
  give clock.current().
}

constant clock is Clock(fixed).
when stamp(clock) is 42 { display "Fixed clock". }
```

Tests can pass `fixed`; production code can pass a wrapper around the real
clock. The same pattern works for random input, files, and network clients.
It does not create a `T has Capability` constraint or a static effect system
(compile-time rules describing which outside operations code may perform).

## Explicit transactions

Transactions need an application-specific participant contract. Keep the
prepare, commit, and rollback operations together, and register rollback
before performing the work.

```foo
define Transaction as record {
  prepare of type function taking () giving failable nothing.
  commit of type function taking () giving failable nothing.
  rollback of type function taking () giving nothing.
}.

function execute(
    participant Transaction,
    work function taking () giving failable nothing
) giving failable nothing {
  constant prepare is participant.prepare.
  constant commit is participant.commit.
  constant rollback is participant.rollback.
  prepare() try.
  after error { rollback(). }
  work() try.
  commit() try.
}
```

This pattern handles a propagated failure in one process. The application must
still define nested transactions, cancellation, irreversible effects, durable
logs, and crash recovery. A general `transaction` block is not current syntax.

## Contracts and properties

Use `contract.require` for a precondition, `contract.ensure` for a
postcondition, and `contract.invariant` for a condition that must always hold.
A failed contract is a panic, not a recoverable failure.

```foo
use contract as contracts.

function withdraw(balance integer, amount integer) giving integer {
  contracts.require(amount greater than 0).
  contracts.require(amount less than or equal to balance).
  constant remaining is balance subtract amount.
  contracts.ensure(remaining greater than or equal to 0).
  give remaining.
}
```

Tests can check a bounded property with `testing.every`. The callback receives
each index from zero up to, but not including, the requested count.

```foo
use testing as check.

function bounded(index unsigned) giving boolean {
  give index less than 100.
}

test "generated indexes stay in range" {
  check.every(100, bounded).
}
```

This is deterministic enumeration (the same range is checked in the same
order), not automatic generation for every value of a type. For varied typed
inputs, wrap an index-to-value function in `Generator[T]` and call `generate`.
The index is reproducible, so a failing value can be recreated.

## Pointer identity

Value equality answers whether values contain the same data. Pointer identity
answers whether two pointers designate the same address. Keep that low-level
question explicit:

```foo
use memory as memory.

constant allocator is memory.system().
constant buffer is memory.allocate(allocator, 16) try.
after { memory.release(allocator, buffer) fallback nothing. }

when memory.identical[byte](buffer, buffer) {
  display "Same allocation".
}
```

Identity does not prove that a pointer is live, correctly aligned, or safe to
dereference (read through the address). Ownership (who must keep and release
the storage) rules still apply.

## Facade modules

An ordinary import is private. Use `public use` when a facade (a public module
over internal modules) should re-export (publish again)
another module's public declarations without changing their names. This
fragment assumes the named internal file exists:

<!-- snippet: context -->
```foo
-- src/service.iv
public use "internal/account.iv".
```

Re-exported declarations participate in normal duplicate-name checks. A
`public use` cannot have an alias. Use a public wrapper when the facade needs to
rename a declaration, adapt arguments, or narrow behavior. This fragment also
depends on the named internal file.

<!-- snippet: context -->
```foo
-- src/service.iv
use "internal/account.iv" as account.

public function lookup(name text) giving failable account.User {
  give account.lookup(name) try.
}
```

Callers import `service` and see `service.lookup`. The wrapper above forwards
behavior deliberately; a plain `public use` preserves the original public
declaration names.

## Explicit boundaries

The current abstractions intentionally stop at these boundaries:

| Area | Current boundary |
| --- | --- |
| Iteration | Custom cursors use `iterator.next`; `for each` accepts compiler-supported collections. |
| Reuse | Records compose other records; there is no inheritance or implicit record subtyping. |
| Time zones | `calendar.Zone` is a fixed UTC offset; named zones need an external versioned database. |
| Transactions | `transaction.execute` coordinates one process; durable and distributed recovery is application policy. |
| Units | `Quantity[D]` checks `add` and `difference` within one dimension; multiplication, division, and conversion are explicit functions. |
| Source generation | Build tasks may emit checked FOO source; syntax macros and compiler plugins are not language features. |

Do not invent extra syntax at these boundaries. Use explicit records and
functions so ownership, failure, and external policy remain visible.

## Check yourself

1. Add an `Email` record with a validating `create` function.
2. Define a `Codec[Email]` that rejects empty text.
3. Create a state machine that rejects a value greater than ten.
4. Replace a real clock dependency with a `Clock` record in a test.
5. Write a property callback that succeeds for indexes below fifty.

Next: [Data and memory](memory.md).
