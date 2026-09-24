# Chapter 11: Reference (The Quick Cheat Sheet)

You don't need to memorize every single word in FOO. This chapter is your quick-reference guide, designed to be scanned in seconds when you need to remember a specific command or keyword.

---

## 1. Daily Commands

| Command | What it does |
| :--- | :--- |
| `foo new <name>` | Creates a brand new project folder. |
| `foo check` | Reads your code and checks for errors (without running it). |
| `foo build` | Compiles your code into a final, optimized executable. |
| `foo run` | Builds and immediately runs your app. |
| `foo test` | Finds and runs all your test blocks. |
| `foo fmt` | Automatically formats your code to look perfect. |
| `foo watch` | Re-checks your code instantly every time you hit save. |
| `foo doctor` | Checks your system and installs missing tools (like Zig/C). |
| `foo bind <file.h>` | Automatically generates FOO bindings from a C header file. |

---

## 2. Core Keywords

| Keyword | Meaning |
| :--- | :--- |
| `constant` | Creates a variable that **cannot** be changed. |
| `mutable` | Creates a variable that **can** be changed. |
| `function` | Defines a reusable block of code. |
| `start()` | The entry point of your application. |
| `give` | Returns a value from a function (like `return`). |
| `use` | Imports another file or module. |
| `public` | Makes a declaration visible to other files. |

---

## 3. Control Flow

| Keyword | Meaning |
| :--- | :--- |
| `when` | Checks a condition (like `if`). |
| `otherwise` | Runs if the condition is false (like `else`). |
| `for each` | Loops through every item in a list. |
| `while` | Loops as long as a condition is true. |
| `break` | Stops a loop completely. |
| `continue` | Skips to the next loop iteration. |
| `match` | Checks a value against specific cases (like `switch`). |
| `after` | Runs cleanup code, even if the function fails (like `defer`). |

---

## 4. Math and Logic

| Symbol | FOO Word |
| :--- | :--- |
| `+` | `plus` |
| `-` | `minus` |
| `*` | `times` |
| `/` | `divided by` |
| `%` | `remainder` |
| `==` | `is` |
| `!=` | `is not` |
| `&&` | `and` |
| `\|\|` | `or` |
| `!` | `not` |

---

## 5. Error Handling

| Keyword | Meaning |
| :--- | :--- |
| `fallible` | Marks a function as "can fail". |
| `try` | Unwraps a fallible value, or stops the function if it fails. |
| `catch` | Provides a fallback value if an operation fails. |
| `Error` | The type used to represent failures. |

---

## 6. Units of Measurement

FOO understands these units natively! You can use them in any math expression.

| Category | Units |
| :--- | :--- |
| **Time** | `seconds`, `milliseconds`, `microseconds`, `nanoseconds` |
| **Data** | `bytes`, `kilobytes`, `megabytes`, `gigabytes`, `terabytes` |
| **Bits** | `bits`, `kilobits`, `megabits`, `gigabits` |

---

## 7. Core Types

| Type | Description |
| :--- | :--- |
| `integer` | Whole numbers (e.g., `42`). |
| `decimal` | Numbers with fractions (e.g., `3.14`). |
| `text` | Strings of characters (e.g., `"hello"`). |
| `boolean` | True or false. |
| `sequence` | A list of values (like an array). |
| `record` | A struct grouping related fields. |
| `choice` | A tagged union (like an enum). |
| `pointer to` | A memory address pointing to a value. |
| `optional` | A value that might be missing (`nothing`). |
| `fallible` | A value that might be an error. |

---

## Summary

Keep this page bookmarked! Whether you are writing your first "Hello World" or optimizing a high-performance server, this cheat sheet will help you find the right FOO word in seconds.

In the next chapter, we will look at **Advanced** features, where we will explore compile-time execution, custom allocators, and hardware-level programming!