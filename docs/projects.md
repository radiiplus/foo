# Projects and Entry Points

`project.json` tells FOO what the project is, where its source lives, which file
runs by default, and which dependencies it uses.

## Create a project

Create a new directory:

```sh
foo new invoice-app
cd invoice-app
```

Or initialize the current empty directory:

```sh
foo new .
```

Both forms create `src/`, `test/`, and `benchmark/`.

## The generated manifest (the project's configuration record)

```json
{
  "schema": 1,
  "name": "invoice-app",
  "language": "1",
  "version": "0.1.0",
  "source": "src",
  "entry": "src/main.iv",
  "entries": {},
  "requires": "base",
  "dependencies": {}
}
```

| Field | Meaning |
| --- | --- |
| `schema` | Version of the project-file format. |
| `name` | Project or package identity. |
| `language` | FOO language version. |
| `version` | Project release version. |
| `source` | Directory containing application modules. |
| `entry` | Default file used by `foo run`. |
| `entries` | Named alternative runnable files. |
| `requires` | Highest toolchain capability (permission level) the project permits. |
| `dependencies` | Package names and version/source constraints (rules limiting acceptable versions or sources). |

Unknown fields are rejected so misspelled configuration does not silently do
nothing.

When omitted, `source` defaults to `src` and `entry` defaults to
`SOURCE/main.iv`. `requires: "base"` selects the portable standard services;
it is a capability level, not a module or package dependency. The `test/` and
`benchmark/` directories are conventional discovery roots created by
`foo new`; `source` may be changed independently.

## Development, optional, and platform dependencies

Use separate objects when a dependency is not needed in every installation:

```json
{
  "dependencies": { "http-client": "^1.2.0" },
  "devDependencies": { "test-data": "~1.0.0" },
  "optionalDependencies": { "metrics": "^2.0.0" },
  "platformDependencies": {
    "windows": { "win-service": "^1.0.0" },
    "linux": { "systemd": "^1.0.0" }
  }
}
```

- `dependencies` are required at runtime.
- `devDependencies` participate in development installs only.
- `optionalDependencies` are omitted when no compatible release exists.
- `platformDependencies` participate only when their platform selector matches.

`foo install` records the selected result in `foo.lock`. Commit that lock file
for applications so another machine resolves the same graph (complete tree of
packages and the packages they need).

## Named entries

Add another executable source:

```foo
-- src/worker.iv
display "Worker started".
```

Then name it in `project.json`:

```json
{
  "entry": "src/main.iv",
  "entries": {
    "worker": "src/worker.iv"
  }
}
```

Run either entry:

```sh
foo run
foo run worker
```

For a one-off run, pass the source path directly:

```sh
foo run src/maintenance.iv
```

Entry names select executable roots. They do not change module visibility or
create separate packages.

## Tests

Place tests under `test/`:

```foo
use testing as check.

test "total starts at zero" {
  constant total is 0.
  check.expect(total is 0).
}
```

Run every test or only one file:

```sh
foo test
foo test test/orders.iv
foo test test/orders.iv --filter total
```

Selecting one file avoids compiling and running unrelated long suites.
If the selected project, file, or filter contains no `test` block and no
explicitly selected `start()` fixture, the command exits unsuccessfully.

## Benchmarks

Each `.iv` file under `benchmark/` is one executable benchmark scenario.

```sh
foo benchmark
foo benchmark parser
foo benchmark benchmark/parser.iv
foo benchmark benchmark/parser.iv --warmup 3 --iterations 25
```

An argument ending in `.iv` selects the exact benchmark file. A name without
the extension is a name filter.

## Watching and editor diagnostics

`foo watch` continuously rebuilds a project in a terminal:

```sh
foo watch
```

The VS Code extension uses `foo lsp` instead. The language server receives each
open or changed document and publishes diagnostics without waiting for a build.
Use the extension's **FOO: Watch Project** command when both editor diagnostics
and continuous build artifacts are useful.

## Build backends

```sh
foo check
foo build --backend zig
foo build --backend c
foo run --explain
```

The default output shows meaningful stages, job count, cache reuse, elapsed
time, and the selected fast or compatibility path. `--explain` adds diagnostic
detail without dumping every backend command.

For profile-guided optimization (using measurements from earlier runs to guide
the compiler), first record representative execution
and then consume the result:

```json
{
  "build": {
    "optimize": "release",
    "coverage": ".artifacts/coverage.json"
  }
}
```

Run the instrumented binary (a build that records execution counts) under a
representative workload (input that resembles real use). Then remove
`coverage` and set `"profile": ".artifacts/coverage.json"` for the optimized
release build. The versioned profile guides inlining (replacing selected calls
with their function bodies); changing its contents invalidates (makes unusable)
the cached artifact (saved build output).

## Generated directories

FOO writes build products, caches, test executables, and benchmark executables
under `.artifacts/`. Installed package contents live under `.foo/`. Keep source,
`project.json`, and `foo.lock`; remove generated outputs with:

```sh
foo clean
```

Next: [Testing](testing.md) or [Benchmarking](benchmarking.md).
