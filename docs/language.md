# The Language

This chapter connects the main FOO features in one place. Each section starts
with a small example, explains what the compiler checks, and points out a
common mistake.

Put a complete example in `src/main.iv`. Check it before running it:

```sh
foo check
foo run
```

FOO uses English words for common operations, but it is not natural-language
guessing. Every sentence has one parse and one checked type.

---

## 1. Variables

In many languages, you have to choose between safety (strict types) and speed (typing less). FOO gives you both using **Type Inference** (where the compiler guesses the type for you based on the value).

### The usual way
FOO looks at `"Daily Report"`, sees the quotes, and knows it is text. It looks
at `0` and knows it is an integer, so most declarations need no repeated type
phrase.
```foo
constant title is "Daily Report".
dynamic count is 0.
```

Use an explicit annotation only when the exact representation matters:

```foo
constant limit of type unsigned 16 is 3.
```

Function parameters use the shorter `name Type` form. Record fields retain
`of type` because they describe a stored layout rather than bind a value.
The inferred type is still fixed. Assigning text to `count` later is a compile
error.

### Named types

Use `define ... as ...` when a domain value deserves its own name:

```foo
define Identity as unsigned.
define Handler[T] as function taking (T) giving nothing.
```

### Mutation, scope, and shadowing

`constant` creates an immutable binding (a named value that cannot change).
`dynamic` creates a binding that can
be changed with `set`; assignment through a `constant` is rejected.

```foo
constant service is "orders".
dynamic attempts is 0.
set attempts to attempts plus 1.
```

Bindings use lexical scope (visibility based on written code blocks). A local
becomes visible after its initializer, a
parameter is visible throughout its function, and a file declaration is
visible throughout its file. An inner block may shadow an outer name, but two
declarations in the same scope cannot use the same name. This inner hiding is
called shadowing. File-level value
initializers must be compile-time evaluable; local constants do not have that
restriction.

Inference chooses the type from the initializer and context. It never adds
truthiness or silently narrows a number. Use an ordinary conversion function
when conversion may lose information; FOO has no cast operator.

---

## 2. Functions: The Building Blocks

Functions in FOO are defined with the word `function`. To keep your public API (the parts of your code other people use) stable, FOO usually asks you to be explicit about what a function *takes* and *gives back*.

```foo
-- Explicit and clear for public APIs
function product(left integer, right integer) giving integer {
  give left multiply right.
}
```

But inside the function, you can still use inference!
```foo
function tax(price decimal) giving decimal {
  -- 'rate' is inferred as decimal automatically
  constant rate is 0.05. 
  
  -- 'total' is inferred as decimal
  dynamic total is price plus (price multiply rate).
  
  give total.
}
```

### Generic functions
What if you want a function that works for *any* type of data? You can use **Generics** (placeholders like `T`) with a `where` clause to set rules.

```foo
-- This works for integers, decimals, or text, as long as they can be compared!
function maximum[T](left T, right T) giving T
  where T is Ord {
  
  when left greater than right { give left. }
  otherwise { give right. }
}
```

### Function rules

Arguments are evaluated from left to right. A call may use positional values,
parameter labels without punctuation, or both with positional values first.
Parameters may have `default` expressions, and a final `are sequence of`
parameter consumes the remaining values. Functions may be overloaded (several
parameter forms share one name); labels, arity (argument count), and input
types must identify one best definition.

```foo
function connect(host text, port integer default 443) giving boolean {
  give true.
}

constant secure is connect(host "example.com").
constant local is connect("localhost", port 8080).
```

Generic parameters use square brackets and can be constrained by `Equatable`,
`Hash`, `Ord`, or `Allocator`. These names are compiler capabilities, not
modules or runtime values. `Equatable` supports equality, `Ord` supports
ordering, `Hash` supports generated hashing, and `Allocator` accepts the opaque
allocator type for generic memory helpers.

Ordinary non-capturing function values can be passed to operations such as
`sequence.map`. Local closures (functions that remember nearby values) may
capture lexical bindings and update captured
dynamic values. They remain scoped to the defining function in this release,
so returning or retaining one is rejected. Recursion (a function calling
itself) is allowed when the
result type is explicit; FOO does not guarantee tail-call optimization.

`give value.` returns immediately. A function giving `nothing` may reach its
closing brace without writing `give nothing.`. Use a positive `when` plus
`give` as a guard clause:

```foo
function absolute(value integer) giving integer {
  when value greater than or equal to 0 { give value. }
  give 0 subtract value.
}
```

`when` is a statement, not a ternary expression. Bind a `dynamic` result or
return from each branch when a decision must produce a value.

---

## 3. Making Decisions: `when` vs `match`

Choose the form based on what you are checking.

### Option A: `when` / `otherwise` (For conditions)
Use this when you are checking if something is true or false (like "is health > 0?").
```foo
dynamic health is 12.

when health is 0 { display "Game Over". }
otherwise when health less than 20 {
  display "Critical!".
}
otherwise { display "Keep going!". }
```

### Option B: `match` (For specific values)
Use this when you are checking a variable against a list of specific options.
```foo
constant status of type integer is 404.

match status {
  case 200 { display "Success". }
  case 404 { display "Not Found". }
  case 500 { display "Server Error". }
  case anything { display "Unknown Status". }
}
```

---

## 4. Math and Logic: Read It Aloud

FOO provides word operators with fixed precedence. Parenthesize mixed
conditions when the grouping matters to the reader.

| Instead of this... | Write this... |
| :--- | :--- |
| `x + y` | `x plus y` |
| `x - y` | `x subtract y` |
| `x * y` | `x multiply y` |
| `x / y` | `x divide y` |
| `x == y` | `x is y` |
| `x != y` | `x is not y` |
| `x && y` | `x and y` |
| `x \|\| y` | `x or y` |

**Example:**
```foo
constant age is 21.
constant identity is true.

when age greater than or equal to 18 and identity {
  display "Access granted".
}
```

---

## 5. Loops: `for each` vs `while`

### The `for each` Loop (For collections)
Use it to do something to every item in a collection:
```foo
use sequence as items.

constant basket is items.append[text](items.create[text], "apple") try.
after { items.release[text](basket) fallback nothing. }

for each fruit in basket {
  display fruit.
}
```

### The `while` Loop (For conditions)
When you want to repeat something until a condition changes.
```foo
dynamic battery is 100.
while battery greater than 0 {
  set battery to battery subtract 1.
  when battery is 10 { skip. }
  display "Motor running".
  when battery is 1 { stop. }
}
```

`skip` moves directly to the next iteration. `stop` leaves the loop completely.

Both target the innermost loop. FOO v1 has no separate infinite `loop` form;
write a Boolean `while` condition explicitly.

---

## 6. Collections and Indexing

FOO v1 does not have collection-literal syntax. Create typed collections with
the standard library, then use their operations. Persistent `sequence`, `map`,
`set`, `queue`, and `stack` edits return new storage. `table` is the mutable,
unordered alternative for text-keyed lookup.

```foo
use sequence as sequences.

constant empty is sequences.create[integer].
constant first is sequences.append[integer](empty, 4) try.
constant values is sequences.append[integer](first, 9) try.
after {
  sequences.release[integer](first) fallback nothing.
  sequences.release[integer](values) fallback nothing.
}

constant initial is values at 0.
for each value in values {
  when value greater than 0 { display "Positive value". }
}
```

Indexing is checked and uses zero-based integer positions. A `sequence of T` is
a bounded view, not an owning growable array. Transformations such as `map`,
`filter`, `sort`, and `dedup` return separately owned results that must be
released after their aliases are no longer used.

---

## 7. Error Handling (`failable`)

Expected operational failures are visible in a `failable T` result. Panics from
failed safety checks are separate and cannot be handled with `fallback`.

You have two ways to handle these errors:

### Propagate with `try`
If you don't want to handle the error right now, put `try` after the operation.
If the operation fails, your *entire* function stops and passes the error up to whoever called it.
```foo
use file as files.
function load giving failable text {
  give files.read("config.json") try.
}
```

### Recover with `fallback`
In FOO, `fallback` expects an alternative value of the exact same type as the success case.

If you just want to provide a backup string, you do this:
```foo
use file as files.

constant config is files.read("config.json") fallback "Default Settings".
```

The fallback is an expression of the same success type. Log separately when the
calling workflow needs an explicit diagnostic.

```foo
use file as files.

constant config is files.read("config.json") fallback "Default Settings".
display config.
```

Top-level statements form the program entry automatically. A function that
gives `nothing` also completes when it reaches the closing brace, so neither an
empty `start` wrapper nor `give nothing.` is routine boilerplate.

When a failable result must be captured, the declaration and propagation remain
two explicit operations:

```foo
use file as files.

constant config is files.read("config.json") try.
```

Here `is` only binds `config`; the postfix `try` applies to `files.read(...)`
and propagates a read failure. Use `fallback` instead
when the current scope can provide a useful replacement.

---

## 8. Automatic Cleanup with `after`

When you open a file or network connection, close it on every ordinary scope
exit. The `after` block covers normal returns, propagated failures, `stop`, and
`skip`; panic and forced process termination do not guarantee cleanup.

```foo
use file as files.
use io as streams.

function process giving failable nothing {
  constant stream is files.open("data.txt", "read") try.
  
  -- This runs for success and propagated failure.
  after { streams.close(stream) fallback nothing. }
  
  -- Do risky work here...
  constant data is streams.read(stream, 1048576) try.
}
```

---


## 9. Modules and Visibility

Every `.iv` file is a module. Declarations are private unless marked `public`.
Ordinary imports stay private and may bind a short alias. This fragment assumes
the project contains `network/server.iv`:

<!-- snippet: project network src/network/server.iv -->
```foo
public function ready giving boolean { give true. }
```

<!-- snippet: project network src/main.iv -->
```foo
use "network/server.iv" as server.
use http as web.

when server.ready { display "Server ready". }
```

`public use "network/server.iv".` re-exports that module's public declarations
without an alias. Duplicate exported names are compile errors.

Bare imports resolve a sibling file, a source-root file, a declared package,
then a standard module. Circular imports and name collisions are errors.
Conditional compilation and feature flags are build-configuration concerns;
they are not source-level `use` modifiers in v1.

---

## 10. Typed Time and Named Quantities

Prefer a typed library value when one exists. The `time` module distinguishes a
duration from an instant and names unit conversions explicitly.

```foo
use memory as memory.
use time as clock.

constant duration is clock.seconds(2).
clock.wait(duration) try.

constant allocator is memory.system.
constant size of type unsigned is 5 multiply 1024 multiply 1024.
constant buffer is memory.allocate(allocator, size) try.
after { memory.release(allocator, buffer) fallback nothing. }
```

The memory API still accepts a byte count, so `size` is named at the boundary.
See [Patterns with today's language](patterns.md) for domain records, codecs,
state machines, injected capabilities, and property checks.


---

## Check yourself

1. Declare a constant and a dynamic value, then update only the dynamic one.
2. Write a function that gives `failable text`. Handle it once with `try` and
   once with `fallback`.
3. Loop over a sequence and stop when a chosen value appears.
4. Create a 50 millisecond `duration` and pass it to `clock.wait`.

Next: [Collections](collections.md).
