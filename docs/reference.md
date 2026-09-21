# Reference

## Core words

Declarations: `function`, `constant`, `mutable`, `public`, `use`.

Types: `integer`, `decimal`, `text`, `boolean`, `nothing`, `pointer to`, `sequence of`, `fallible`, `optional`, and function types written `function taking (A, B) giving C`.

Flow: `when`, `otherwise`, `while`, `for each`, `in`, `give`, `try`, `catch`, `after`, `break`, `continue`, and `unreachable`.

Compilation: `native`, `unsafe`, `extern`, `export`, `where`, `is`, and attributes such as `#[repr(C)]`, `#[packed]`, and `#[derive(...)]`.

## File rules

Every `.iv` file is one compilation unit and one namespace. A module declaration is invalid. Imports expose only `public` declarations. The compiler reports circular imports and missing targets with a suggested path.

## Grammar notation

Text literals use double quotes with escapes; raw text uses `raw"..."`. Comments begin with `--`. Numbers accept decimal, hexadecimal, binary, octal, underscores, and decimals. Statements end with a period where the grammar requires a complete sentence.
