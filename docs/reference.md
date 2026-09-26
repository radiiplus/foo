# Chapter 11: Reference (The Quick Cheat Sheet)

You don't need to memorize every single word in FOO. This chapter is your quick-reference guide, designed to be scanned in seconds when you need to remember a specific command or keyword.

---

## 1. Daily Commands

| Command | What it does |
| :--- | :--- |
| `foo login` | Authenticates with GitHub through the device flow, printing the URL and code and opening the system browser when available. |
| `foo init [directory\|.]` | Scaffolds a publishable package. |
| `foo publish` | Validates and publishes the current committed package. |
| `foo add <package[@version]> [url\|path]` | Adds a registry, URL, Git, or local dependency. |
| `foo install` | Resolves the manifest, fetches exact commits, and writes `foo.lock`. |
| `foo search <query>` | Searches the public Git registry index. |
| `foo info <package[@version]>` | Shows a canonical package release. |
| `foo new <name>` | Creates a brand new project folder. |
| `foo new .` | Initializes the current directory without overwriting project files. |
| `foo check` | Reads your code and checks for errors (without running it). |
| `foo build` | Compiles your code into a final, optimized executable. |
| `foo run` | Builds and immediately runs your app. |
| `foo test` | Finds and runs all your test blocks. |
| `foo fmt` | Automatically formats your code to look perfect. |
| `foo watch` | Re-checks your code instantly every time you hit save. |
| `foo doctor` | Reports installed and missing toolchain components. |
| `foo bind <file.h>` | Automatically generates FOO bindings from a C header file. |

Long-running commands share the FOO operation view. Add `--explain` to `build`,
`run`, `check`, `install`, `update`, `remove`, `publish`, or `toolchain` to show
diagnostic details that are hidden by default. Use `--json` with compiler
commands when another program needs structured progress events.

---

## 2. Core Keywords

| Keyword | Meaning |
| :--- | :--- |
| `constant` | Creates a variable that **cannot** be changed. |
| `dynamic` | Creates a variable that **can** be changed. |
| `function` | Defines a reusable block of code. |
| `define ... as ...` | Introduces a named type. |
| `start()` | Optionally groups an explicit entry point; top-level statements run without it. |
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
| `stop` | Stops a loop completely. |
| `skip` | Skips the current iteration and moves to the next. |
| `match` | Checks a value against specific cases (like `switch`). |
| `after` | Runs cleanup code, even if the function fails (like `defer`). |

---

## 4. Math and Logic

| Symbol | FOO Word |
| :--- | :--- |
| `+` | `plus` |
| `-` | `subtract` |
| `*` | `multiply` |
| `/` | `divide` |
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
| `try` | Follows a fallible value and unwraps it, or stops the function if it fails. |
| `fallback` | Provides an alternative value if an operation fails. |
| `Error` | The type used to represent failures. |

---

## 6. Quantities

FOO v1 uses ordinary numeric expressions for quantities. Library APIs document
their base units; give converted values names such as `twoSeconds` or
`fiveMegabytes` at the call site.

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
