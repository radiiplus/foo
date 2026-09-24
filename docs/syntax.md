# Chapter 13: Syntax Guide (The Complete FOO Dictionary)

Welcome to the complete syntax reference for FOO. This chapter is a plain-language dictionary of every keyword, operator, and sentence structure in the language. 

Use this guide when you know *what* you want to do, but just need to remember the exact FOO word to do it.

---

## 1. Declarations (Creating Things)

| Syntax | Plain Meaning | Example |
| :--- | :--- | :--- |
| `constant` | Creates a value that cannot be changed. | `constant pi is 3.14.` |
| `mutable` | Creates a value that can be changed. | `mutable score is 0.` |
| `function` | Defines a reusable block of code. | `function greet() { ... }` |
| `public` | Makes a declaration visible to other files. | `public constant max_users is 100.` |
| `use` | Imports another file or module. | `use io.` or `use "math.iv".` |
| `type` | Creates a nickname (alias) for a complex type. | `type UserID is integer 64.` |
| `record` | Groups related fields together. | `record Point { x of type integer. y of type integer. }` |
| `choice` | Defines a value that can be one of several variants. | `choice Color { case red. case blue. }` |

---

## 2. Core Types

| Type | Plain Meaning | Example |
| :--- | :--- | :--- |
| `integer` | Whole numbers (defaults to 64-bit). | `42` or `-10` |
| `unsigned` | Whole numbers, positive only. | `100` |
| `decimal` | Numbers with fractions (defaults to 64-bit). | `3.14` |
| `boolean` | True or false. | `true` or `false` |
| `byte` | A single 8-bit unsigned number. | `255` |
| `text` | A string of characters. | `"hello world"` |
| `nothing` | The absence of a value (like void). | `nothing` |
| `pointer to` | A memory address pointing to a value. | `pointer to integer` |
| `sequence of` | A dynamic list of values. | `sequence of text` |
| `optional` | A value that might be missing. | `optional text` |
| `fallible` | A value that might be an error. | `fallible integer` |
| `vector` | A fixed-size array for SIMD math. | `vector[4, decimal]` |

---

## 3. Math and Logic (Word Operators)

| Instead of... | Write this... | Example |
| :--- | :--- | :--- |
| `+` | `plus` | `5 plus 5` |
| `-` | `minus` | `10 minus 2` |
| `*` | `times` | `4 times 4` |
| `/` | `divided by` | `20 divided by 4` |
| `%` | `remainder` | `10 remainder 3` |
| `==` | `is` | `x is 10` |
| `!=` | `is not` | `x is not 0` |
| `>` | `greater than` | `health greater than 0` |
| `<` | `less than` | `ammo less than 5` |
| `>=` | `is at least` | `age is at least 18` |
| `<=` | `is at most` | `speed is at most 100` |
| `&&` | `and` | `true and false` |
| `\|\|` | `or` | `true or false` |
| `!` | `not` | `not ready` |

---

## 4. Control Flow (Making Decisions)

### Conditionals (`when` / `otherwise`)
Use this when you are checking if a condition is true or false.
```foo
when condition {
  -- runs if true
}
otherwise when other_condition {
  -- runs if first was false, second is true
}
otherwise {
  -- runs if everything above was false
}
```

### Matching (`match` / `case`)
Use this when you are checking a single variable against specific values. It is cleaner and safer than using long `when/otherwise` chains.

```foo
match status_code {
  case 200 { display "OK". }
  case 404 { display "Not Found". }
  case _   { display "Unknown". } -- The underscore catches anything else
}
```

**The Superpower: Exhaustiveness Checking**
FOO's compiler mathematically guarantees that you haven't forgotten a possible outcome. If you use `match` on a `boolean` and forget to include a `case` for either `true` or `false`, FOO will stop the build and throw an error. You are forced to handle every edge case!

**Advanced Guards (`when` inside `case`)**
You can add an extra condition to a specific case:
```foo
match user_role {
  case "admin" when user_level is 99 { 
    display "Super Admin". 
  }
  case "admin" { 
    display "Regular Admin". 
  }
  case _ { 
    display "Guest". 
  }
}
```

### Loops
```foo
-- Repeat while a condition is true
while health greater than 0 { ... }

-- Loop over every item in a list
for each item in shopping_cart { ... }

-- Stop a loop completely
break.

-- Skip to the next iteration
continue.
```

---

## 5. Functions and Returns

```foo
-- A function that returns nothing
function do_work() of type nothing {
  -- Do work here
  give nothing.
}

-- A function that returns an integer
function add(a of type integer, b of type integer) of type integer {
  give a plus b.
}
```

---

## 6. Error Handling

| Keyword | Plain Meaning | Example |
| :--- | :--- | :--- |
| `try` | Unwraps a fallible value, or bails out if it fails. | `try file read "data.txt".` |
| `catch` | Provides a fallback value if the left side fails. | `load() catch "default".` |
| `after` | Runs cleanup code when the scope ends (success or fail). | `after { close(file). }` |

---

## 7. Built-in Commands & Units

### Output
```foo
display "Hello!".
log message "System started.".
log error "Something went wrong.".
```

### Units of Measurement (Quantity Literals)
FOO automatically converts these into their base numerical values at compile time.

*   **Time:** `seconds`, `milliseconds`, `microseconds`, `nanoseconds`
*   **Data:** `bytes`, `kilobytes`, `megabytes`, `gigabytes`, `terabytes`

```foo
time sleep 2 seconds.
constant ram is 16 gigabytes.
```

---

## 8. Native Interoperability

```foo
-- Import a C function directly
use "c" function printf(fmt of type pointer to byte) of type integer.

-- Write a raw C block
native c function fast_math(a of type integer) of type integer {
  return a * a;
}

-- Write raw Assembly
asm {
  // hardware instructions here
}
```

---

## Summary

That’s the entire FOO language in a nutshell! It is a small, highly readable vocabulary that compiles down to incredibly powerful machine code. 

Thank you for reading the FOO Book. Now go build something amazing!