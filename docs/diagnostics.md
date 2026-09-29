# Diagnostics

FOO diagnostics (compiler messages about problems or useful context) are
designed for two audiences: concise terminal output for a person and exact
structured records (data split into named fields) for editors and automation.

## Grouped terminal errors

Equivalent errors are printed once in human-readable output. The first source
excerpt shows the problem, followed by every affected line:

```text
src/main.iv:4:3

  display load.
  ^^^^^^^^^^^^^^^

  This call can fail. Use try or fallback to handle its error

Affected lines: 4, 9, 15
```

Grouping requires the same diagnostic code (a stable identifier for one kind
of problem), explanation, context, suggestion, notes, and fix. Diagnostics with
related spans stay separate because collapsing
them could hide an important relationship. Repeated locations are removed and
line numbers are sorted. When the same problem spans several files, FOO prints
an `Affected locations` list grouped by file.

JSON and LSP (Language Server Protocol, used by code editors) diagnostics are
never collapsed. Each source span (the exact start and end of affected code) remains a
separate record so an editor can underline every occurrence and apply fixes at
the correct locations.

## Color and accessibility

Terminal diagnostics use the FOO palette: red identifies failures and source
markers, cyan identifies locations and help, and muted text identifies context.
The wording and symbols still carry all meaning when color is unavailable.

Set `NO_COLOR` to any value, or set `TERM=dumb`, to disable ANSI color (terminal
control codes used to add color). JSON
output never contains color escapes.

## Output modes

The default mode shows the location, source excerpt, explanation, and most
useful correction. Use `--explain` or `--verbose` for diagnostic codes, related
locations, and technical context:

```sh
foo check
foo check --explain
foo check --json
```

`NO_COLOR=1` disables ANSI color for integrations that need plain text. Output
shape is selected with command flags rather than an environment variable.

## Reading a diagnostic

A diagnostic location is one-based for people. Machine spans (exact source
ranges used by tools) are zero-based
UTF-8 byte offsets (positions counted in encoded bytes) with an exclusive end
(the end position is not included). Tabs occupy one source column but are
expanded to four-cell tab stops in the displayed excerpt.

Fix the first independent error before chasing later messages. FOO keeps
related locations attached to conflicts such as duplicate declarations and
type mismatches, and it avoids merging those relationships into a generic
count.

## Diagnostic codes

Codes identify categories; the message and highlighted source remain the
authoritative explanation for a particular occurrence.

| Code | Category | Code | Category |
| --- | --- | --- | --- |
| `FOO0000` | Unexpected token | `FOO0018` | Variant not found |
| `FOO0001` | Unterminated input | `FOO0019` | Scope escape |
| `FOO0002` | Invalid construct | `FOO0020` | Undefined value |
| `FOO0003` | Invalid escape | `FOO0021` | Declaration not exported |
| `FOO0004` | Invalid digit | `FOO0022` | Already imported |
| `FOO0005` | Syntax error | `FOO0023` | Non-exhaustive match |
| `FOO0006` | Missing declaration | `FOO0024` | Unreachable case |
| `FOO0007` | Extra input | `FOO0025` | Backend error |
| `FOO0008` | Duplicate declaration | `FOO0026` | Link error |
| `FOO0009` | Hidden declaration | `FOO0027` | C binding error |
| `FOO0010` | Name conflict | `FOO0028` | Native public API escape |
| `FOO0011` | Module or item not found | `FOO0029` | Dependency conflict |
| `FOO0012` | Circular dependency | `FOO0030` | Package hash mismatch |
| `FOO0013` | Type mismatch | `FOO0031` | Package not found |
| `FOO0014` | Value is not callable | `FOO0032` | Error context |
| `FOO0015` | Value is not indexable | `FOO0033` | Uncaught error |
| `FOO0016` | Value is not iterable | `FOO0034` | Test failed |
| `FOO0017` | Field not found | | |
