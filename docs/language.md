# Chapter 3: The Language (Writing Code That Reads Like a Book)

Welcome to the core of FOO! In this chapter, we are going to look at the actual words and sentences you will use to build your apps.

If you are coming from languages like C++, Java, or even Python, you might be used to a screen cluttered with symbols: `{}`, `()`, `==`, `!=`, `&&`, `||`. FOO’s **Parser** (the brilliant part of the compiler that reads your code) was designed to eliminate "symbol soup." Instead, FOO uses natural, English words that make your code's intent instantly obvious.

Let’s look at the building blocks of FOO, and how to write them as quickly as possible.

---

## 1. Variables: Strict Safety, Zero Boilerplate

In many languages, you have to choose between safety (strict types) and speed (typing less). FOO gives you both using **Type Inference** (where the compiler guesses the type for you based on the value).

### The "Explicit" Way (For maximum clarity)
If you want to be 100% precise, you can state the type explicitly:
```foo
constant title of type text is "Daily Report".
mutable count of type integer is 0.
```

### The "Fast" Way (How you'll actually code)
FOO looks at `"Daily Report"`, sees the quotes, and knows it's text. It looks at `0` and knows it's an integer. You can drop the `of type` completely!
```foo
constant title is "Daily Report".
mutable count is 0.
```
**Why this is awesome:** You get the bulletproof safety of a compiled language (the compiler will still stop you from adding text to a number later), but your code looks as clean as a dynamic language like Python.

---

## 2. Functions: The Building Blocks

Functions in FOO are defined with the word `function`. To keep your public API (the parts of your code other people use) stable, FOO usually asks you to be explicit about what a function *takes* and *gives back*.

```foo
-- Explicit and clear for public APIs
function multiply(left of type integer, right of type integer) of type integer {
  give left times right.
}
```

But inside the function, you can still use inference!
```foo
function calculate_tax(price of type decimal) of type decimal {
  -- 'rate' is inferred as decimal automatically
  constant rate is 0.05. 
  
  -- 'total' is inferred as decimal
  mutable total is price plus (price times rate). 
  
  give total.
}
```

### Generic Superpowers
What if you want a function that works for *any* type of data? You can use **Generics** (placeholders like `T`) with a `where` clause to set rules.

```foo
-- This works for integers, decimals, or text, as long as they can be compared!
function max_value[left of type T, right of type T] of type T 
  where T is Comparable {
  
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
when health is 0 {
  display "Game Over".
}
otherwise when health less than 20 {
  display "Critical!".
}
otherwise {
  display "Keep going!".
}
```

### Option B: `match` (For specific values)
Use this when you are checking a variable against a list of specific options (like a switch statement). It’s cleaner and faster to read.
```foo
match status_code {
  case 200 { display "Success". }
  case 404 { display "Not Found". }
  case 500 { display "Server Error". }
  case _   { display "Unknown Status". } -- The underscore matches anything else
}
```

---

## 4. Math and Logic: Read It Aloud

FOO replaces confusing symbols with English words. This makes your logic impossible to misread.

| Instead of this... | Write this... |
| :--- | :--- |
| `x + y` | `x plus y` |
| `x * y` | `x times y` |
| `x == y` | `x is y` |
| `x != y` | `x is not y` |
| `x && y` | `x and y` |
| `x \|\| y` | `x or y` |

**Example:**
```foo
-- Hard to read: if (user.age >= 18 && user.has_id)
-- Easy to read:
when user.age is at least 18 and user.has_id {
  grant_access().
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
mutable battery is 100.
while battery greater than 0 {
  run_motor().
  set battery to battery minus 1.
}
```

---

## 6. Bulletproof Error Handling (`fallible`)

In FOO, errors aren't hidden surprises that crash your app. They are **First-Class Values** (regular data you can see and handle). If a function can fail, it is marked as `fallible`.

You have two ways to handle these errors:

### Way 1: The `try` Keyword (Pass the buck)
If you don't want to handle the error right now, use `try`. If the function fails, your *entire* function stops and passes the error up to whoever called it.
```foo
function load_config() of type fallible text {
  -- If file.read fails, this whole function fails immediately.
  give try file read "config.json".
}
```

### Way 2: The `catch` Operator (Provide a fallback)
In FOO, `catch` is an operator (just like `plus` or `times`). It doesn't create a new variable; it simply expects you to provide a **fallback value** of the exact same type as the success case. 

If you just want to provide a backup string, you do this:
```foo
constant config is load_config() catch "Default Settings".
```

If you want to run some code (like logging the error) *and then* provide the backup string, you use a block `{ ... }`. In FOO, a block automatically evaluates to its last expression. 

```foo
start() {
  -- If load_config() fails, the block runs, logs the error, 
  -- and evaluates to the fallback text "Default Settings".
  constant config is load_config() catch {
    log error "Failed to load file!".
    "Default Settings"
  }.
  
  display config.
  
  -- Because start() returns 'nothing', we must explicitly give it.
  give nothing.
}
```
*Why `give nothing.` at the end?* Because FOO is strictly typed, every function must explicitly `give` a value that matches its signature. Since `start()` is the entry point and returns `nothing` (FOO's version of `void`), the compiler mathematically requires you to end the function with `give nothing.` to prove you finished it safely.

---

## 7. Automatic Cleanup with `after`

When you open a file or a network connection, you *must* close it, even if your code crashes. FOO makes this effortless with the `after` block.

```foo
function process_data() {
  constant file is try open("data.txt").
  
  -- This block runs NO MATTER WHAT happens next.
  -- Success? It runs. Error? It runs.
  after { close(file). }
  
  -- Do risky work here...
  constant data is try file read_all().
}
```

---


## 8. Quality of Life: Human-Readable Units

FOO’s parser is so smart it understands **Units of Measurement**. You never have to write confusing math like `1024 * 1024` or `1000 * 1000`. You just write what you mean.

```foo
-- Wait for 2 seconds (FOO converts this to nanoseconds automatically)
time sleep 2 seconds.

-- Allocate 5 megabytes of memory
constant buffer is try memory.allocate(5 megabytes).

-- Set a timeout
constant timeout is 500 milliseconds.
```

**Supported Units:**
*   **Time:** `seconds`, `milliseconds`, `microseconds`, `nanoseconds`
*   **Data:** `bytes`, `kilobytes`, `megabytes`, `gigabytes`, `terabytes`

This makes your code self-documenting. `sleep(2000000000)` is hard to read. `sleep 2 seconds.` is impossible to misunderstand.


---

## Summary: The FOO Philosophy

Every feature in FOO is designed to reduce **Cognitive Load** (the mental energy you spend just trying to read the code). 

By allowing you to drop `of type` when the compiler can guess it, using English words for math, and forcing you to handle errors explicitly, FOO lets you write code that is safe, fast, and incredibly easy to read.

In the next chapter, we will look at **Data and Memory**, where you will learn how FOO manages RAM so efficiently that you almost never have to think about it!