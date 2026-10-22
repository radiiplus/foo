# Feature Status

FOO is under active development. The [specifications](../specs/README.md)
define intended contracts; they do not establish support on every compiler
target. This page summarizes the active route and its main limits. Check the
[QBE target table](qbe.md) before depending on a target-specific service.

## Language and tools

The compiler accepts `.iv` source with `constant` and `dynamic` bindings,
functions, records and choices, `optional` and `failable` values, `when`,
`while`, `for each`, `match`, `try`, `fallback`, and `after`. The
[language guide](language.md), [functions guide](functions.md), and
[syntax guide](syntax.md) show the current forms. Frontend coverage is in
`test/parse/`, `test/types/`, and `test/sema/`; a frontend test alone does not
qualify a target's generated code.

The active build backend is QBE. Project configuration uses `project.ivc`,
and package commands write `.ivl` dependency locks. The CLI builds, runs,
tests, and benchmarks programs in dev and release modes. See
[projects](projects.md), [testing](testing.md), and
[benchmarking](benchmarking.md) for commands and prerequisites.

## Target limits

- Hosted Windows x64, Linux x64, and Linux ARM64 have QBE dev and release
  correctness gates for the cases listed in [QBE support](qbe.md). The gate
  does not cover every library service or every possible FFI signature.
- Freestanding ELF, UEFI, WASI, WASI threads, and SPIR-V products have
  separate target gates and restrictions. A successful hosted test does not
  qualify these routes. See [target gates](../test/backend/qbe/TARGETS.md).
- Linux shared-library linking, Apple/BSD native targets, and debug,
  coverage, profile, and sanitizer products are not supported by the current
  QBE build route.
- High-level WASI services, hosted task cancellation, and arbitrary shared
  state races remain outside the qualified target gates.

FOO has no `async` or `await` keywords, direct Rust ABI declarations,
escaping captured closures, source-level lifetime annotations, or tracing
garbage collector. Use the documented library and C ABI boundaries where
applicable.

For a new compiler revision or a target-sensitive feature, run the relevant
gate from [QBE Target Gates](../test/backend/qbe/TARGETS.md) and check the
generated behavior. The current repository tests, rather than a specification
entry alone, determine what has been verified.
