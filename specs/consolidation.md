# Canonical source forms

Version: 1.

FOO has one public spelling for each ordinary language concept. Source files
use file-level declarations, `define` for types, `dynamic` for changing values,
`pointer to T` for pointers, and `sequence of T` for bounded sequence views.

Functions use sentence-like parameters and `giving` results. Generic bounds
follow the declaration in a `where` clause. Equality uses `is` and `is not`;
ordering uses `less than`, `greater than`, and their `or equal to` forms.
Indexing uses `value at index`.

Loops use `while` or `for each`. Mutation uses `set`, `increase`, or `decrease`.
Loop control uses `stop` and `skip`. Failable operations use postfix `try` or
`fallback`, and `after` is the cleanup construct.

Native boundaries use `extern "C"`, `native c`, `native asm`, or an unqualified
`native` contract selected by project configuration. Backend implementation
details are not FOO source forms.

Unit uses `nothing`; optional absence uses `null`. A pointer is non-null unless
wrapped in `optional`. Byte, character, and text are distinct semantic types.
The full rules are in [grammar](grammar.md), [types](types.md), and
[native interfaces](native.md).

Import aliases preserve a meaningful distinction: an aliased import exposes
only qualified member access. `display value.`, `input`, and `report value.`
are intentional high-level I/O forms; ordinary function calls use
parentheses.
