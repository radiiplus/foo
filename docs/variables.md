# Variables

FOO has two value declarations: `constant` for a binding (a name connected to
a value) that cannot change, and `dynamic` for one that can.

## Constants

```foo
constant application is "Ledger".
constant attempts is 3.
constant production is false.
```

The compiler infers (works out automatically) each type from its initial value. A constant cannot later
be assigned a different value.

Use constants by default. They make it clear that a value remains stable.

## Dynamic values

Declare a value as `dynamic` when it must change, then use `set`.

```foo
dynamic attempts is 0.
set attempts to attempts plus 1.
increase attempts by 1.

when attempts is 2 {
  display "Two attempts".
}
```

`set` changes an existing binding. It does not declare a new one.

Use intent-specific arithmetic for ordinary counters and quantities:

```foo
dynamic attempts is 0.
dynamic remaining is 10.
increase attempts by 1.
decrease remaining by 2.
```

These forms perform the same checked arithmetic as `plus` and `subtract`, then
store the result back into the dynamic binding.

## Singular and plural declarations

Use `is` for one value and `are` when a name represents a sequence of values:

```foo
use sequence as sequences.

constant current is "Ada".
constant active is sequences.create[text]().
constant user is current.
constant users are active.
```

`is` and `are` do not disable type checking. They communicate the role of the
binding to readers while the initializer still determines its exact type.

## Explicit types

Inference is usually enough. Add `of type` when the exact representation is
part of the program's contract.

```foo
constant port of type unsigned 16 is 8080.
dynamic balance of type decimal 32 is 12.50.
```

The initializer must fit the declared type. FOO does not silently convert
unrelated values.

## Names

Use one clear word such as `limit`, `account`, or `duration`. Names are
case-sensitive: `total` and `Total` are different.

Standard-library functions follow the same rule. Prefer a precise operation
such as `line`, not `readLine` or `read_line`.

## Scope

A name is available after its declaration. A block creates an inner lexical
scope (the part of the written code where that name is visible).

```foo
constant message is "Outside".

when true {
  constant message is "Inside".
  display message.
}

display message.
```

Output:

```text
InsideOutside
```

The inner declaration shadows the outer one only inside the block. Declaring
the same name twice in one scope is an error.

## Named types

Use `define ... as ...` to give a type a domain-specific name.

```foo
define Identity as unsigned.
define Temperature as decimal.

constant owner of type Identity is 42.
constant room of type Temperature is 21.5.
```

This improves APIs because a reader can understand why a number exists, not
only how it is stored.

## Try it

1. Declare a constant named `project` and display it.
2. Declare `dynamic completed is 0.`.
3. Increase `completed` three times with `increase completed by 1.`.
4. Add a `when` block that displays `"Done"` when the value is 3.
5. Change `dynamic` to `constant` and use `foo check` to see why mutation is
   rejected.

## Common mistakes

| Problem | Fix |
| --- | --- |
| Assigning to a constant | Use `dynamic` only if mutation is required. |
| Writing `attempts = 1` | Write `set attempts to 1.` |
| Repeating a type everywhere | Let local declarations infer obvious types. |
| Reusing a name in one scope | Rename one binding or move it into an inner block. |

Next: [Types and values](types.md).
