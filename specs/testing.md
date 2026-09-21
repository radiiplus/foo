# Testing
Version: 1.

## Language tests
A file-level `test "description" { ... }` declares an isolated test. Its body follows the same return and error rules as `start`: returning nothing succeeds, an unhandled failure fails the test, and a panic is reported as a test failure. Test descriptions must be unique within a file.

Tests are private and excluded from ordinary executable entry selection. Each test has its own scope arena; resources and child tasks finish before that arena is released. Tests must not depend on execution order or share mutable state without an explicit isolated fixture contract.

`foo test` discovers tests in project source files and excludes generated output and dependency contents. A project's `start` function is not an implicit test. An explicit test failure returns a nonzero command status; unsupported target execution is reported separately from a successful compilation.

`foo test path --filter name` selects descriptions containing the given text.
`foo test std` runs the shipped standard-library fixtures. An explicitly selected
fixture file with a `start` and no test blocks runs that entry point. Where test
blocks exist, the application entry point is never executed alongside them.
`--backend c` or `--backend zig` selects the compiler backend.

`foo test --watch` rediscovers tests after source and configuration changes,
reruns affected tests, and reuses successful results whose imported source and
declared native inputs are unchanged. Failures remain visible until fixed.
Tests containing native code or C interfaces rerun on every observed change;
their external inputs cannot safely be inferred from FOO imports alone.
Generated executables stay under `.artifacts/test` for debugging and build reuse.
Test executions have a 60-second timeout. Native fixture inputs can be declared
under `tests.NAME.sources` in project.json, relative to the project root.

## Conformance snapshots
Every stage has deterministic golden outputs. A snapshot envelope has `format: "foo.snapshot"`, `version: 1`, `stage`, `case`, `inputs`, `options`, `expected` and `diagnostics`. Inputs are a map of package-relative paths to UTF-8 source strings; options include the language version and any target or capability selection. Expected output is either the canonical stage object or exact normalized text. Diagnostics follow the diagnostic record contract.

| Stage | Required observations |
| --- | --- |
| `tokens` | Token kinds, decoded values and source spans, including comments and lexical failures |
| `syntax` | Declaration and expression trees, precedence, file boundaries and recovery |
| `types` | Resolved names, canonical types, constraints, effects and region relationships |
| `ir` | Canonical versioned FOO IR, traces, cleanup and panic edges |
| `c` | C substrate output and foreign layouts |
| `asm` | Target-selected substrate output and calling conventions |
| `diagnostics` | Exact plain output and machine records |
| `project` | Normalized configuration and dependency resolution |
| `graph` | File namespaces, exported/private symbols, dependency order and entry selection |
| `installation` | Component manifests, integrity failures and capability readiness |

Snapshots exclude timestamps, host-specific absolute paths and unstable allocation identities. Text uses LF line endings. A changed expected result is a conformance difference that requires explanation; successful parsing alone does not establish execution correctness.

Execution comparisons cover observable values, output bytes, errors, panics, cleanup, ownership and synchronization. Foreign tests compare sizes, alignments, offsets and callback behavior against the declared ABI. Target-specific expectations are explicit rather than silently skipped.

## Formatting and editors
`foo fmt` emits only canonical v1 syntax, preserving comments and literal values. It is idempotent. A short leading responsibility comment remains at the top of a file. Formatting cannot change which dot is a member selector or statement terminator.

Formatting preserves blank lines between statements and multiline function
parameters. Native payloads remain verbatim. Sentence calls may normalize to
the corresponding parenthesized call without changing their meaning.

`foo lsp` supplies coded diagnostics, declaration navigation and checked hover
types. Function descriptions read “name is a function taking integer and integer,
giving integer”. Open, unsaved imported files participate in checking; changes
refresh dependent open documents. Closing a document restores its disk contents.

The editor identity is `foo`, the TextMate scope is `source.foo`, and files use `.iv`. Lexical highlighting distinguishes linking words, type constructors, types, functions, literals and comments while respecting the selected editor theme. Semantic highlighting may refine lexical scopes without changing token meaning.

## Incremental correctness
`foo watch` observes source, configuration, dependency and embedded-resource changes. It reports a failed build and keeps observing; fixing the error triggers another build.

A reused result must match its language and format versions, target, capability selection, relevant options, input contents and dependency interfaces. Reusing unchanged parsing, types or IR is permitted only when those dependencies remain valid. A clean build and an incremental build must produce equivalent observable results.

Conformance cases include unchanged builds, private-body edits, public-signature edits, dependency changes, configuration changes, corrupt cache entries and recovery after errors. Performance claims require measured inputs and timings; textual resemblance between sources is never a correctness argument for reuse.
