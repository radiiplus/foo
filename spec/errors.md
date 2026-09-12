# Error Model (MVL-1)

## The Single Error Type
There are **no error sets**. There is exactly one global `Error` type.
An `Error` value contains:
1. `code`: A global, open enum of error categories (e.g., `OutOfMemory`, `Io`, `Parse`, `Panic`).
2. `context`: An optional string slice providing human-readable details.
3. `source`: An optional source location (file, line, column) where the error originated.
4. `chain`: An optional pointer to a parent `Error`, forming a linked list for tracing.

## Error Unions
- `!T` denotes a function or operation that may return `T` or `Error`.
- Allocation failure **always** returns `!T` (specifically, `![]T` or `!*T`), never panics, unless explicitly forced.

## Control Flow
- `try expr;`: If `expr` evaluates to `Error`, the current function immediately returns that `Error`. Otherwise, it evaluates to the inner `T`.
- `catch`: `let x = expr catch { fallback };` handles the `Error` and provides a fallback value of type `T`.
- `errdefer expr;`: Executes `expr` **only** if the current scope exits via an error return (`try` or explicit `return error`). Normal `defer` executes on all exits.

## Guarantees
- Errors are values. They are never thrown as exceptions.
- Error traces are automatically populated by the compiler in `dev` optimize mode. In `release` mode, `source` and `chain` are stripped to zero cost.