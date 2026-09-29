# Testing

FOO tests are file-level blocks compiled with the same type, ownership (who is
responsible for a resource), error, and backend (code generator) rules as
application code.

`foo new` creates `test/main.iv` for you. Put behavior checks in `test/`; use
`src/` for application code and `benchmark/` for performance measurements.

Start with one small statement: arrange a value, run the operation, then check
the result. A failed check, compile error, or selection containing no tests
makes `foo test` exit unsuccessfully.

```foo
use testing as check.

test "addition returns the total" {
  constant total is 20 plus 22.
  check.expect(total is 42).
}
```

You do not need a `start` function in a test file. Each `test "name" { ... }`
block is discovered and run separately, so one failure can be reported without
turning the file into an application.

Test descriptions must be unique within a file. Tests are private, do not
become executable entry points, and each receives its own scope arena (a group
of temporary memory released together). Reaching
the end succeeds; an unhandled failure, failed assertion (a check that must be
true), panic (an unrecoverable program failure), or timeout
fails the test.

## Running tests

```sh
foo test
foo test test/orders.iv
foo test --filter tax
foo test --backend c
foo test --backend zig
foo test --watch
foo test std
```

`foo test` discovers `test "description" { ... }` blocks across the project,
including `src/` and `test/`, and excludes dependencies, benchmarks, and
generated output. Ordinary calls to `testing` functions outside a test block
are not separate tests. `--filter` matches
text in the description. Pass one file when you only want that file's tests;
FOO does not compile or run the other test files. `--watch`
rediscovers and reruns affected tests after a source or configuration change.
Each execution has a 60-second timeout.

The `testing` module currently provides focused assertions:

| Function | Check |
| :--- | :--- |
| `expect(value)` | Boolean value is true. |
| `same[T](actual, expected)` | Two values of the same `Equatable` type match. |
| `number(actual, expected)` | Unsigned integer values match. |
| `positive(value)` | Unsigned integer is positive. |
| `real(actual, expected)` | Decimal values match. |
| `point(actual, expected)` | Optional unsigned point is present and matches. |
| `every(count, property)` | The property returns true for every index from zero to `count subtract 1`. |

`same` works for text, integers, decimals, Booleans, optionals, sequences, and
records or choices that derive `Equatable`:

```foo
use testing as check.

test "generic equality" {
  check.same(1, 1).
  check.same("FOO", "FOO").
}
```

## Check a bounded property

Write a function taking an unsigned index and returning `boolean`, then pass it
to `every`:

```foo
use testing as check.

function bounded(index unsigned) giving boolean {
  give index less than 100.
}

test "indexes stay in range" {
  check.every(100, bounded).
}
```

This runs exactly 100 cases: `0` through `99`. It is deterministic and does
not generate arbitrary values of a type. For varied typed inputs, define an
index-to-value function, store it in `Generator[T]`, and call `generate`:

```foo
use testing as check.

function sample(index unsigned) giving unsigned {
  give index plus 1.
}

function positive(value unsigned) giving boolean {
  give value greater than 0.
}

test "generated values stay positive" {
  constant generator is check.Generator[unsigned](sample).
  check.generate[unsigned](100, generator, positive).
}
```

The failing index is reproducible. FOO does not silently invent random values
for a type.

## Native fixtures

Tests that need C support declare their native sources in `project.json`:

```json
{
  "tests": {
    "database": {
      "sources": ["test/native/database.c"]
    }
  }
}
```

The key matches the fixture filename without `.iv`. Paths are relative to the
project root and are linked only for that fixture.

## Current boundaries

The built-in runner does not yet define mocking (replacing a dependency with a
controlled test version), stubbing (returning a prepared test response), or
fixture-lifecycle syntax (setup and cleanup rules for test data). Backend
coverage instrumentation (tracking which code ran) exists in the compiler pipeline, but
`foo test` does not yet expose a stable coverage reporting flag. Use
[`foo benchmark`](benchmarking.md) for repeatable application measurements.
Type-driven `test every T` syntax is not implemented; use `Generator[T]` and
`generate` explicitly. These are tooling and language boundaries, not hidden
syntax.
