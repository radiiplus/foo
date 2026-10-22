# Projects and Entry Points

`project.ivc` tells FOO what the project is, where its source lives, which file
runs by default, and which dependencies it uses.
Its built-in capability is defined in `src/config/project.cap` and generated
under `.artifacts/.cap/project.cap`.

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

```ivc
capability "project"
project {
  name is "invoice-app"
  version is "0.1.0"
  source is "src"
  entry is "src/main.iv"
  entries {}
  build {
    output is "output"
  }
}
```

| Field | Meaning |
| --- | --- |
| `schema` | Project schema version; defaults to 1 and usually stays implicit. |
| `name` | Project or package identity. |
| `language` | FOO language version; defaults to 1. |
| `version` | Project release version. |
| `source` | Directory containing application modules. |
| `entry` | Default file used by `foo run`. |
| `entries` | Named alternative runnable files. |
| `requires` | Highest toolchain capability (permission level) the project permits; defaults to base. |
| `dependencies` | Package names and version/source constraints (rules limiting acceptable versions or sources). |
| `build.output` | Project-relative directory for completed apps and libraries; defaults to `output`. |
| `build.type` | Optional artifact kind: `exe`, `static`, `shared`, `object`, or `shader`. |
| `build.icon` | Reserved for Windows executable resources; currently rejected by QBE. |

Unknown fields are rejected so misspelled configuration does not silently do
nothing.

Without `build.type`, FOO builds runnable source as an executable. Source with
only declarations builds a native static library or a WASM/WASI object; SPIR-V
targets build shaders. `foo build --kind KIND` overrides this for one build,
and `foo build --target TARGET` selects a specific target. A configured target
list uses the current host when it is present.

Use `foo config check` to validate the manifest and any explicitly selected
capabilities. `foo config emit` writes a deterministic, output-only
`.artifacts/config/config.cimg`; builds still read source configuration.
For other domains, define `.cap/NAME.cap` and select it from any
`NAME.ivc`. A `.cap` file declares allowed fields and their rules; an `.ivc`
file selects capabilities and supplies values. For example,
`.cap/service.cap` declares a port:

```cap
namespace is "service"
version is 1
fields {
  port { type is "integer" required enable }
}
```

`service.ivc` selects that schema and supplies a value:

```ivc
capability "service"
service { port is 8080 }
```

Run `foo config check service.ivc` or `foo config emit service.ivc` to validate
or emit that configuration independently of the project manifest.
The selected schema is generated as `.artifacts/.cap/NAME.cap`.
The [configuration specification](../specs/configuration.md) describes imports,
merge rules, `.cap` definitions, and current limitations.

When omitted, `source` defaults to `src` and `entry` defaults to
`SOURCE/main.iv`. `requires: "base"` selects the portable standard services;
it is a capability level, not a module or package dependency. The `test/` and
`benchmark/` directories are conventional discovery roots created by
`foo new`; `source` may be changed independently.

## Development, optional, and platform dependencies

Use separate objects when a dependency is not needed in every installation:

```ivc
dependencies { http-client is "^1.2.0" }
devDependencies { test-data is "~1.0.0" }
optionalDependencies { metrics is "^2.0.0" }
platformDependencies {
  windows { win-service is "^1.0.0" }
  linux { systemd is "^1.0.0" }
}
```

- `dependencies` are required at runtime.
- `devDependencies` participate in development installs only.
- `optionalDependencies` are omitted when no compatible release exists.
- `platformDependencies` participate only when their platform selector matches.

`foo install` records the selected result in JSON `foo.ivl`, which has editor
syntax coloring. Commit that lock file
for applications so another machine resolves the same graph (complete tree of
packages and the packages they need).

## Named entries

Add another executable source:

```foo
-- src/worker.iv
display "Worker started".
```

Then name it in `project.ivc`:

```ivc
project {
  entry is "src/main.iv"
  entries { worker is "src/worker.iv" }
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
Test build files are kept under `.artifacts/test` in a stable directory for
each suite, backend, and mode. Concurrent runs of the same suite wait for the
current build and execution to finish. Self-contained C fast-path builds reuse
their executable when the generated program and native compiler are unchanged.
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

Build tasks can generate a record from structured values before compilation:

```ivc
build {
  tasks {
    schema {
      kind is "record"
      output is "schema.iv"
      values {
        name is "Schema"
        fields is [
          { name is "id" type is "unsigned" },
          { name is "ready" type is "boolean" }
        ]
      }
    }
  }
}
```

The task validates identifiers and primitive field types, writes under
`.artifacts/build/generated/`, and generated source is parsed and checked
when imported like any other FOO module.

```sh
foo check
foo build --backend qbe
foo run --explain
foo build --compact
```

The default output shows meaningful stages, job count, cache reuse, elapsed
time, and the selected fast or compatibility path. `--explain` adds diagnostic
detail without dumping every backend command.
The progress display counts completed source checks, product builds, test runs,
and benchmark samples according to the selected command. It shows `?%` and
elapsed time until enough consistent timing history exists to estimate a
percentage and approximate time remaining. A completed command reaches 100%.
`--compact` shows the same status on one updating terminal line. `--json`
includes progress counts, percentage, timing availability, and estimated
remaining seconds in each progress event.
Completed noncached work updates per-project timing estimates in
`.artifacts/progress.json`; cache hits do not replace cold-build timings.

Completed products are written to `output/` by default:

```text
output/
|-- app.exe          # Windows application
`-- libcore.a        # Static library on Linux
```

The `spirv-vulkan1.3` shader product uses the SPIR-V route selected by the QBE
driver and the bundled validator. Linux shared-library output is not supported
by the current linker path; Windows x64 shared products use DLLs. See
[QBE Backend Support](qbe.md) for target gates.

Choose another project-local directory when packaging or deployment expects a
different layout:

```ivc
build { output is "dist/native" }
```

FOO creates the directory, including missing parent directories, during the
build. The path cannot be absolute, leave the project, or overlap source,
tests, benchmarks, dependencies, or `.artifacts`. All configured products are
placed directly in the output directory with the filename required by their
kind and target platform.

The scaffold includes an icon asset, but QBE application builds reject
`build.icon`. The compiler's own Windows release icon is embedded by its
separate packaging build.

## Optional application releases

Ordinary projects do not need release configuration. Add it only when an
application is ready to be staged for deployment:

```ivc
license is "MIT"
release {
  directory is "release"
  icon is "assets/icon.svg"
  license is "LICENSE"
  readme is "README.md"
  files is ["NOTICE"]
  sign { provider is "auto" }
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

`release.json` records the relative path, size, and SHA-256 of each staged
payload, including support files and any bundled runtime library. `SHA256SUMS`
also covers `release.json`.

Signing is opt-in. `provider: "auto"` selects Authenticode for Windows and GPG
for Linux ELF executables. The current QBE build route has no macOS target.
Credentials remain outside the
manifest. Release signing covers executable and shared-library products;
static archives remain unsigned:

| Provider | Environment | Result |
| --- | --- | --- |
| `gpg` | `FOOSIGNER` | GPG fingerprint; creates a detached armored `.asc` signature. |
| `authenticode` | `FOOSIGNER` | Certificate-store thumbprint (certificate identifier); `signtool` embeds the signature. |
| `codesign` | `FOOSIGNER` | Signs an existing Apple binary; the QBE route cannot build one. |

Set `release.sign.timestamp` to the timestamp service supplied by the Windows
certificate provider. Tool commands can be overridden with `GPG`, `SIGNTOOL`,
or `CODESIGN`. Sign one existing product without creating a bundle with:

```sh
foo sign output/invoice-app.exe --provider authenticode
```

QBE application builds currently reject `build.coverage` and `build.profile`.
Use [Benchmarking](benchmarking.md) to measure release products; see
[QBE Backend Support](qbe.md) for other unsupported build options.

## Generated directories

FOO writes completed app, static-library, and shared-library products under
`output/`, or the directory selected by `build.output`. Compiler-generated
source, object files, cache metadata, test executables, and benchmark
executables remain under `.artifacts/`. Installed package contents live under
`.foo/`. Keep source, `project.ivc`, and `foo.ivl`; remove the configured
output directory and internal build state with:

```sh
foo clean
```

Next: [Testing](testing.md) or [Benchmarking](benchmarking.md).
