<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
    <img src="assets/logo-light.svg" alt="FOO logo" width="96" height="96">
  </picture>
</p>

<h1 align="center">FOO</h1>

<p align="center">Readable systems programming with sentence-like syntax and native output.</p>

FOO is a systems programming language for writing clear `.iv` programs without giving up control over native targets. The `foo` command checks, formats, tests, builds, and runs projects, with C and Zig available as output backends.

```iv
function greet(name of type text) of type nothing {
  display "Hello, " plus name.
  give nothing.
}

start() {
  greet("world").
  give nothing.
}
```

## Install

Download the archive for your system from the [latest GitHub release](https://github.com/radiiplus/foo/releases/latest). FOO currently ships production binaries for Windows x64 and Linux x64.

The release also includes an npm package. With Node.js 22.13 or newer installed, download `foo-0.1.0.tgz` and run:

```sh
npm install --global ./foo-0.1.0.tgz
foo version
foo doctor
```

To use a platform archive without installing it globally:

```powershell
# Windows
.\bin\foo.cmd version
```

```sh
# Linux
./bin/foo version
```

FOO manages the pinned Zig backend used for native builds. `foo doctor` shows the compiler, backend, C tools, and target support available on your computer.

## Create A Project

```sh
foo new hello
cd hello
foo check
foo run
```

A FOO project contains a `project.json` manifest and one or more `.iv` files. `start()` is the default entry point.

## Everyday Commands

| Command | Purpose |
| --- | --- |
| `foo check` | Check syntax, names, types, and ownership without building |
| `foo run` | Build and run the current project |
| `foo build` | Produce the configured native artifact |
| `foo test` | Discover and run named test blocks |
| `foo fmt file.iv` | Format a source file |
| `foo watch` | Recheck the project when files change |
| `foo doc sequence` | Show documentation for a library module |
| `foo doctor` | Inspect the installed toolchain and target support |

Use `--backend c` or `--backend zig` to select a backend when a command supports it. Use `--target` and `-mcpu` for target-specific builds.

## Learn FOO

- [Getting started](docs/start.md)
- [Language guide](docs/language.md)
- [Syntax reference](docs/syntax.md)
- [Standard library](docs/library.md)
- [Platforms and targets](docs/platforms.md)
- [FOO for VS Code](https://github.com/radiiplus/foo/tree/main/editors/textmate)

The complete documentation starts at [docs/README.md](docs/README.md).
