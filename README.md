<p align="center">
  <img src="assets/dark.svg" alt="FOO logo" width="96" height="96">
</p>

<h1 align="center">FOO</h1>

<p align="center">
  A compiled systems language with sentence-like syntax and native C and Zig backends.
</p>

<p align="center">
  <a href="https://fooregistry.web.app/docs/overview">Documentation</a> &middot;
  <a href="https://fooregistry.web.app/downloads">Downloads</a> &middot;
  <a href="https://github.com/radiiplus/foo/releases">Releases</a> &middot;
  <a href="https://marketplace.visualstudio.com/items?itemName=radiiplus.foo-iv">VS Code</a>
</p>

FOO is designed for readable application and systems code without giving up
native compilation. Its language, compiler, standard library, package tooling,
tests, benchmarks, editor integration, and release workflow are developed in
this repository.

> [!NOTE]
> FOO is under active development. Review the [feature status](docs/status.md)
> and [changelog](CHANGELOG.md) before depending on a language, library, or ABI
> contract in production.

## First program

FOO permits executable statements at the top level, so a small program does
not need a wrapper function or an I/O import:

```foo
display "Hello, world!".
```

Run it inside a project with:

```sh
foo run
```

## Capabilities

| Area | Current direction |
| --- | --- |
| Language | Checked, sentence-like syntax with top-level statements, pattern matching, generics, choices, postfix `try`, and `fallback`. |
| Native output | C and Zig backends with target-aware builds and reachability-based executable emission. |
| Memory and safety | Explicit ownership, regions, cleanup, sealing, checked arithmetic, and low-level capabilities. |
| Standard library | Portable `file`, `http`, `json`, task, thread, channel, process, and system services with advanced operations where needed. |
| Tooling | Project scaffolding, incremental builds, tests, benchmarks, package resolution, live LSP diagnostics, and formatter support. |
| Distribution | Configurable product directories, named executables, command linking, release staging, checksums, icons, and optional signing. |

`foo build --explain` and `foo run --explain` report selected runtime paths,
cache reuse, parallel jobs, and optimization decisions without exposing raw
backend command noise. The [optimization guide](docs/tuning.md) documents the
implemented paths and the evidence required before making performance claims.

## Install

Download the current package from the [FOO download page](https://fooregistry.web.app/downloads)
or [GitHub Releases](https://github.com/radiiplus/foo/releases).

| Platform | Package |
| --- | --- |
| Windows x64 | `foo-windows-x64.exe` |
| Debian or Ubuntu x64 | `foo-amd64.deb` |
| Debian or Ubuntu ARM64 | `foo-arm64.deb` |

Install a Debian package with `apt`, then verify the managed toolchain:

```sh
sudo apt install ./foo-amd64.deb
foo doctor
```

For Ubuntu running through Termux/proot on an ARM64 Android device, install
`foo-arm64.deb` inside the Ubuntu session. The package targets Ubuntu's glibc
environment and does not run directly in the Termux Android environment.

On Windows, run the installer and open a new terminal before calling
`foo doctor`.

## Create a project

```sh
foo new hello
cd hello
foo run
```

Use `foo new .` to initialize the current directory. A new application starts
with this layout:

```text
hello/
|-- assets/
|   |-- icon.ico
|   `-- icon.svg
|-- benchmark/
|   `-- main.iv
|-- src/
|   `-- main.iv
|-- test/
|   `-- main.iv
|-- .gitignore
`-- project.json
```

Application source belongs in `src/`; correctness checks and performance
scenarios have separate discovery roots. Finished applications and libraries
are written to `output/` by default, while `.artifacts/` remains compiler-owned
workspace. Both the entry file and product directory can be changed in
`project.json`.

## Language at a glance

Functions declare parameter and result types without repeating `of type`:

```foo
function greet(name text) giving text {
  give "Hello, " plus name plus "!".
}

display greet("vibes").
```

Failures remain visible in ordinary control flow. Postfix `try` propagates a
failure to the caller, while `fallback` supplies a local alternative:

```foo
use file as files.

constant settings is files.read("settings.json") fallback "{}".
display settings.
```

The [language guide](docs/language.md) covers declarations, control flow,
functions, types, ownership, errors, concurrency, interoperation, and the
standard library in depth.

## Everyday commands

| Command | Purpose |
| --- | --- |
| `foo check` | Type-check the project without producing a final application. |
| `foo run` | Build and run the default entry. |
| `foo run worker` | Build and run a named entry from `project.json`. |
| `foo build` | Build products without running them. |
| `foo test [file.iv]` | Run all tests or select one test file. |
| `foo benchmark [name\|file.iv]` | Measure all benchmarks or a selected scenario. |
| `foo watch` | Recheck the project as files change. |
| `foo doctor` | Report the state of the compiler and managed toolchain. |

Use `--backend c` or `--backend zig` where backend selection is supported.
Application arguments follow `--`, for example
`foo run worker -- input.json --verbose`.

## Packages

Registry dependencies use the package name and an optional version constraint:

```sh
foo add http-client
foo add http-client@1.4.2
foo install
```

External dependencies take an explicit local path or URL:

```sh
foo add shared ../shared
foo add widgets https://github.com/example/widgets.git
foo install
```

After installation, source code imports the package name, such as
`use shared.`. The package manager records exact resolutions in `foo.lock`.
See [Packages and Dependencies](docs/packages.md) for local, Git, optional,
development, and platform-specific dependencies.

## Multiple programs and direct commands

Projects can map short names to additional entry files in `project.json`:

```json
{
  "entry": "src/main.iv",
  "entries": {
    "worker": "src/worker.iv"
  }
}
```

Run `foo run worker`, or link it as a command that no longer needs the `foo`
prefix:

```sh
foo link worker --name hello-worker
foo path
hello-worker
foo unlink hello-worker
```

`foo link` does not edit shell profiles or the Windows registry. The
[project guide](docs/projects.md) explains how to place the printed directory
on `PATH` once.

## Releases and signing

Release packaging is optional. When configured, `foo release` performs a
release build and stages the selected products, license, readme, icon, extra
files, `release.json`, and `SHA256SUMS` in a versioned directory.

```sh
foo release
foo release --sign
foo sign output/hello.exe --provider authenticode
```

Signing identities remain outside `project.json`. GPG, Authenticode, and Apple
codesign providers read the selected identity or fingerprint from
`FOOSIGNER`. See [Projects and Entry Points](docs/projects.md#optional-application-releases)
and the [release guide](docs/releasing.md) before preparing distributable
artifacts.

## Editor support

The official [FOO extension for Visual Studio Code](https://marketplace.visualstudio.com/items?itemName=radiiplus.foo-iv)
provides syntax highlighting, live compiler diagnostics, checked hover
information, navigation, snippets, and project commands. It starts `foo lsp`
automatically; use **FOO: Watch Project** when continuous terminal builds are
also useful.

## Documentation

| Resource | Content |
| --- | --- |
| [FOO Guide](docs/README.md) | Learning path from installation through systems programming. |
| [Language Guide](docs/language.md) | Syntax, semantics, types, memory, errors, and concurrency. |
| [Project Guide](docs/projects.md) | Entries, output, tests, benchmarks, releases, and signing. |
| [Package Guide](docs/packages.md) | Registry, URL, Git, and local dependencies. |
| [CLI Reference](docs/reference.md) | Commands and selection rules. |
| [Feature Status](docs/status.md) | Implemented, partial, and planned behavior. |
| [Changelog](CHANGELOG.md) | Latest changes and release history. |

The hosted documentation is available at
[fooregistry.web.app/docs/overview](https://fooregistry.web.app/docs/overview).

## Build from source

Repository development requires Node.js 22.13 or newer, Nim 2.2, and the
platform prerequisites described in the [contributing guide](CONTRIBUTING.md).

```sh
npm install
npm run native:build
node bin/foo.mjs doctor
```

## Contributing and security

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a change and follow the
[Code of Conduct](CODE_OF_CONDUCT.md). Use the issue templates for bugs,
features, and implementation inconsistencies. Report vulnerabilities privately
through the process in [SECURITY.md](SECURITY.md).

## License

FOO is available under either the [MIT License](LICENSE-MIT) or the
[Apache License 2.0](LICENSE-APACHE), at your option.
