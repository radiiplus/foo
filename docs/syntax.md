# Chapter 13: Syntax Guide (The Complete FOO Dictionary)

Welcome to the complete syntax reference for FOO. This chapter is a plain-language dictionary of every keyword, operator, and sentence structure in the language. 

Use this guide when you know *what* you want to do, but just need to remember the exact FOO word to do it.

---

## 1. Declarations (Creating Things)

| Syntax | Plain Meaning | Example |
| :--- | :--- | :--- |
| `constant` | Creates a value that cannot be changed. | `constant pi is 3.14.` |
| `dynamic` | Creates a value that can be changed. | `dynamic score is 0.` |
| `function` | Defines a reusable block of code. | `function greet() { ... }` |
| `public` | Makes a declaration visible to other files. | `public constant maxUsers is 100.` |
| `use` | Imports another file or module. | `use io.` or `use "math.iv".` |
| `define` | Introduces a named type. | `define UserID as integer 64.` |
| `record` | Groups related fields together. | `define Point as record { x of type integer. y of type integer. }.` |
| `choice` | Defines a value that can be one of several variants. | `define Color as choice { red. blue. }.` |

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
| `-` | `subtract` | `10 subtract 2` |
| `*` | `multiply` | `4 multiply 4` |
| `/` | `divide` | `20 divide 4` |
| `%` | `remainder` | `10 remainder 3` |
| `==` | `is` | `x is 10` |
| `!=` | `is not` | `x is not 0` |
| `>` | `greater than` | `health greater than 0` |
| `<` | `less than` | `ammo less than 5` |
| `>=` | `greater than or equal to` | `age greater than or equal to 18` |
| `<=` | `less than or equal to` | `speed less than or equal to 100` |
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
otherwise when otherCondition {
  -- runs if first was false, second is true
}
otherwise {
  -- runs if everything above was false
}
```

### Matching (`match` / `case`)
Use this when you are checking a single variable against specific values. It is cleaner and safer than using long `when/otherwise` chains.

```foo
match statusCode {
  case 200 { display "OK". }
  case 404 { display "Not Found". }
  case anything { display "Unknown". }
}
```

**The Superpower: Exhaustiveness Checking**
FOO's compiler mathematically guarantees that you haven't forgotten a possible outcome. If you use `match` on a `boolean` and forget to include a `case` for either `true` or `false`, FOO will stop the build and throw an error. You are forced to handle every edge case!

**Advanced Guards (`when` inside `case`)**
You can add an extra condition to a specific case:
```foo
match userLevel {
  case 99 when accountActive {
    display "Super Admin".
  }
  case 10 {
    display "Regular Admin".
  }
  case anything {
    display "Guest".
  }
}
```

### Loops
```foo
-- Repeat while a condition is true
while health greater than 0 { ... }

-- Loop over every item in a list
for each item in shoppingCart { ... }

-- Stop a loop completely
stop.

-- Skip to the next iteration
skip.
```

---

## 5. Functions and Returns

```foo
-- A function that returns nothing
function doWork() {
  -- Do work here
}

-- A function that returns an integer
function add(a integer, b integer) giving integer {
  give a plus b.
}
```

---

## 6. Error Handling

| Keyword | Plain Meaning | Example |
| :--- | :--- | :--- |
| `try` | Unwraps the preceding fallible value, or bails out if it fails. | `file.read("data.txt") try.` |
| `fallback` | Provides an alternative if the left side fails. | `load() fallback "default".` |
| `after` | Runs cleanup code when the scope ends. | `after { io.close(stream) fallback nothing. }` |

---

## 7. Built-in Commands & Units

### Output
```foo
use log.

display "Hello!".
log.showMessage("System started.").
log.showError("Something went wrong.").
```

### Quantities
Use ordinary numeric expressions in the units required by the library.

```foo
constant twoSeconds is 2000000000.
time.sleep(twoSeconds) try.
constant sixteenGibibytes is 16 multiply 1024 multiply 1024 multiply 1024.
```

---

## 8. Native Interoperability

```foo
-- Declare a C function directly
extern "C" function puts(value pointer to byte) giving integer.

-- Write a raw C block
native c function fastMath(a integer) giving integer {
  return a * a;
}

-- Write raw Assembly
asm {
  /* hardware instructions here */
}
```

---

## Summary

That’s the entire FOO language in a nutshell! It is a small, highly readable vocabulary that compiles down to incredibly powerful machine code. 

Thank you for reading the FOO Book. Now go build something amazing!
