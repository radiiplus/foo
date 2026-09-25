# Chapter 3: The Language (Writing Code That Reads Like a Book)

Welcome to the core of FOO! In this chapter, we are going to look at the actual words and sentences you will use to build your apps.

If you are coming from languages like C++, Java, or even Python, you might be used to a screen cluttered with symbols: `{}`, `()`, `==`, `!=`, `&&`, `||`. FOO’s **Parser** (the brilliant part of the compiler that reads your code) was designed to eliminate "symbol soup." Instead, FOO uses natural, English words that make your code's intent instantly obvious.

Let’s look at the building blocks of FOO, and how to write them as quickly as possible.

---

## 1. Variables: Strict Safety, Zero Boilerplate

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
constant retryLimit of type unsigned 16 is 3.
```

Function parameters use the shorter `name Type` form. Record fields retain
`of type` because they describe a stored layout rather than bind a value.
**Why this is awesome:** You get the bulletproof safety of a compiled language (the compiler will still stop you from adding text to a number later), but your code looks as clean as a dynamic language like Python.

### Named types

Use `define ... as ...` when a domain value deserves its own name:

```foo
define UserID as unsigned 64.
define Handler[T] as function taking (T) giving nothing.
```

---

## 2. Functions: The Building Blocks

Functions in FOO are defined with the word `function`. To keep your public API (the parts of your code other people use) stable, FOO usually asks you to be explicit about what a function *takes* and *gives back*.

```foo
-- Explicit and clear for public APIs
function multiply(left integer, right integer) giving integer {
  give left multiply right.
}
```

But inside the function, you can still use inference!
```foo
function calculateTax(price decimal) giving decimal {
  -- 'rate' is inferred as decimal automatically
  constant rate is 0.05. 
  
  -- 'total' is inferred as decimal
  dynamic total is price plus (price multiply rate).
  
  give total.
}
```

### Generic Superpowers
What if you want a function that works for *any* type of data? You can use **Generics** (placeholders like `T`) with a `where` clause to set rules.

```foo
-- This works for integers, decimals, or text, as long as they can be compared!
function maxValue[T](left T, right T) giving T
  where T is Ord {
  
  when left greater than right { give left. }
  otherwise { give right. }
}
```

---

## 3. Making Decisions: `when` vs `match`

FOO gives you two beautiful ways to handle logic, depending on what you are checking.

### Option A: `when` / `otherwise` (For conditions)
Use this when you are checking if something is true or false (like "is health > 0?").
```foo
when health is 0 { display "Game Over". }
otherwise when health less than 20 {
  display "Critical!".
}
otherwise { display "Keep going!". }
```

### Option B: `match` (For specific values)
Use this when you are checking a variable against a list of specific options (like a switch statement). It’s cleaner and faster to read.
```foo
match statusCode {
  case 200 { display "Success". }
  case 404 { display "Not Found". }
  case 500 { display "Server Error". }
  case anything { display "Unknown Status". }
}
```

---

## 4. Math and Logic: Read It Aloud

FOO replaces confusing symbols with English words. This makes your logic impossible to misread.

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
-- Hard to read: if (user.age >= 18 && user.hasId)
-- Easy to read:
when user.age greater than or equal to 18 and user.hasId {
  grantAccess().
}
```

---

## 5. Loops: `for each` vs `while`

### The `for each` Loop (For collections)
When you want to do something to every item in a list.
```foo
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
  runMotor().
  when battery is 1 { stop. }
}
```

`skip` moves directly to the next iteration. `stop` leaves the loop completely.

---

## 6. Bulletproof Error Handling (`fallible`)

In FOO, errors aren't hidden surprises that crash your app. They are **First-Class Values** (regular data you can see and handle). If a function can fail, it is marked as `fallible`.

You have two ways to handle these errors:

### Way 1: The `try` Keyword (Pass the buck)
If you don't want to handle the error right now, put `try` after the operation.
If the operation fails, your *entire* function stops and passes the error up to whoever called it.
```foo
use file as files.
function loadConfig() giving fallible text {
  give files.read("config.json") try.
}
```

### Way 2: The `fallback` Operator (Provide an Alternative)
In FOO, `fallback` expects an alternative value of the exact same type as the success case.

If you just want to provide a backup string, you do this:
```foo
constant config is loadConfig() fallback "Default Settings".
```

The fallback is an expression of the same success type. Log separately when the
calling workflow needs an explicit diagnostic.

```foo
constant config is loadConfig() fallback "Default Settings".
display config.
```

Top-level statements form the program entry automatically. A function that
gives `nothing` also completes when it reaches the closing brace, so neither an
empty `start()` wrapper nor `give nothing.` is routine boilerplate.

When a fallible result must be captured, the declaration and propagation remain
two explicit operations:

```foo
constant config is files.read("config.json") try.
```

Here `is` only binds `config`; the postfix `try` applies to `files.read(...)`
and propagates a read failure. Use `fallback` instead
when the current scope can provide a useful replacement.

---

## 7. Automatic Cleanup with `after`

When you open a file or a network connection, you *must* close it, even if your code crashes. FOO makes this effortless with the `after` block.

```foo
use file as files.
use io as streams.

function processData() giving fallible nothing {
  constant stream is files.open("data.txt", "read") try.
  
  -- This block runs NO MATTER WHAT happens next.
  -- Success? It runs. Error? It runs.
  after { streams.close(stream) fallback nothing. }
  
  -- Do risky work here...
  constant data is streams.read(stream, 1048576) try.
}
```

---


## 8. Named Quantities

Library APIs document their base units. Use ordinary word-based arithmetic and
give converted values descriptive names at the boundary.

```foo
use memory.
use time.

constant twoSeconds is 2000000000.
time.sleep(twoSeconds) try.

constant allocator is memory.system().
constant fiveMegabytes is 5 multiply 1024 multiply 1024.
constant buffer is memory.allocate(allocator, fiveMegabytes) try.
```

Name converted values such as `twoSeconds` and `fiveMegabytes` so their units
stay clear at the call site.


---

## Summary: The FOO Philosophy

Every feature in FOO is designed to reduce **Cognitive Load** (the mental energy you spend just trying to read the code). 

By using compact parameter types, English words for math, and explicit failure handling, FOO keeps code safe, fast, and easy to read.

In the next chapter, we will look at **Data and Memory**, where you will learn how FOO manages RAM so efficiently that you almost never have to think about it!
