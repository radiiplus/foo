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

Both forms create `src/`, `test/`, `benchmark/`, and `assets/`. The assets
directory contains `icon.ico` for Windows executable resources and `icon.svg`
for release packages and desktop metadata.

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
  "dependencies": {},
  "build": { "output": "output", "icon": "assets/icon.ico" }
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
| `build.output` | Project-relative directory for completed apps and libraries; defaults to `output`. |
| `build.icon` | Optional project-relative `.ico` file embedded in Windows executable products. |

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

### Link a command

The same named entry can become a direct command:

```sh
foo link worker --name invoice-worker
foo path
```

Then run the linked command directly:

```text
invoice-worker
```

`foo link` writes a launcher (a small command file) under FOO's user bin
directory. `foo path` prints that directory. Add it to `PATH` once to run linked
commands without the `foo` prefix. Set `FOO_BIN` before linking to choose another
bin directory. Remove the launcher with:

```sh
foo unlink invoice-worker
```

Without an entry argument, `foo link` links the default entry and uses the
project name as the command name. Linking is explicit and does not edit shell
profiles or the Windows registry. Linked commands forward their arguments. The
equivalent local form places application arguments after `--`:

```sh
foo run worker -- input.json --verbose
```

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
explicitly selected `start` fixture, the command exits unsuccessfully.

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

Completed products are written to `output/` by default:

```text
output/
|-- app.exe          # Windows application
|-- libcore.a        # Static library on Linux
`-- libservice.so    # Shared library on Linux
```

Choose another project-local directory when packaging or deployment expects a
different layout:

```json
{
  "build": {
    "output": "dist/native"
  }
}
```

FOO creates the directory, including missing parent directories, during the
build. The path cannot be absolute, leave the project, or overlap source,
tests, benchmarks, dependencies, or `.artifacts`. All configured products are
placed directly in the output directory with the filename required by their
kind and target platform.

The generated `build.icon` is used only for Windows executable products.
Libraries and non-Windows targets do not invoke a Windows resource compiler.
The C backend requires `llvm-rc` for an icon-enabled Windows build; set
`FOO_RESOURCE_COMPILER` when it is installed under another command name. The
managed Zig backend reads the resource directly.

## Optional application releases

Ordinary projects do not need release configuration. Add it only when an
application is ready to be staged for deployment:

```json
{
  "license": "MIT",
  "release": {
    "directory": "release",
    "icon": "assets/icon.svg",
    "license": "LICENSE",
    "readme": "README.md",
    "files": ["NOTICE"],
    "sign": {
      "provider": "auto"
    }
  }
}
```

`license` at the project root is the SPDX expression (a standard machine-readable
license name). `release.license` is the actual license file copied into the
bundle. `release.files` can add notices, desktop files, configuration examples,
or other deployment material. Every path must remain inside the project.

Create a release bundle:

```sh
foo release
foo release --sign
```

FOO performs a release-mode build and writes
`release/NAME-VERSION-TARGET/`. The directory contains the products, selected
support files, `release.json`, and `SHA256SUMS` (hashes used to detect changed
bytes). Existing content for that exact name, version, and target is replaced;
other staged releases remain untouched.

Signing is opt-in. `provider: "auto"` selects Authenticode for Windows, GPG for
Linux ELF executables, and codesign for macOS. Credentials remain outside the
manifest. Release signing covers executable and shared-library products;
static archives remain unsigned:

| Provider | Environment | Result |
| --- | --- | --- |
| `gpg` | `FOOSIGNER` | GPG fingerprint; creates a detached armored `.asc` signature. |
| `authenticode` | `FOOSIGNER` | Certificate-store thumbprint (certificate identifier); `signtool` embeds the signature. |
| `codesign` | `FOOSIGNER` | Apple signing identity; `codesign` embeds the signature. |

Set `release.sign.timestamp` to the timestamp service supplied by the Windows
certificate provider. Tool commands can be overridden with `GPG`, `SIGNTOOL`,
or `CODESIGN`. Sign one existing product without creating a bundle with:

```sh
foo sign output/invoice-app.exe --provider authenticode
```

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

FOO writes completed app, static-library, and shared-library products under
`output/`, or the directory selected by `build.output`. Compiler-generated
source, object files, cache metadata, test executables, and benchmark
executables remain under `.artifacts/`. Installed package contents live under
`.foo/`. Keep source, `project.json`, and `foo.lock`; remove the configured
output directory and internal build state with:

```sh
foo clean
```

Next: [Testing](testing.md) or [Benchmarking](benchmarking.md).
