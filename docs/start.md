# Chapter 2 — Getting started

## Installing the toolchain

FOO provides the `foo` command. Install Node 22.13 or newer, then install the package or work from a checkout:

```sh
npm ci
npm link
foo version
foo doctor
```

The toolchain manages the pinned backend it needs. A user's globally installed Zig version is not used as an implicit substitute. `foo doctor` reports the compiler, backend, C tools, target support, and optional runners available on the host.

## Using the exported artifact

Maintainers create the ready-to-use workspace with:

```sh
npm run build
```

This writes `.artifacts/compiler`. Copy or pack that directory; it contains the `foo` entry point, the standard library, native resources, project files, and the complete FOO book. Open `foo.artifact.json` to see its format version, compiler version, entry point, and included roots. A user of the artifact runs `foo` directly and does not need TypeScript, `tsx`, or the source checkout.

## The first project

```sh
foo new lines
cd lines
foo check
foo run
```

The project has a `project.json` manifest and one or more `.iv` files. When `src` exists, FOO discovers `.iv` files below it; otherwise it discovers files in the project directory. The entry point is `start()` unless the manifest names another entry.

```iv
-- main.iv
function greet(name of type text) of type nothing {
  display name.
  give nothing.
}

start() {
  greet("Positive Vibes").
  give nothing.
}
```

Comments begin with `--`. Periods close sentence statements. Braces delimit a body or a control-flow branch. Whitespace is for readability and does not change the meaning of a complete sentence.

## A second file

Each file supplies its own namespace. Put this in `math.iv`:

```iv
public function add(left of type integer, right of type integer) of type integer {
  give left plus right.
}
```

Import it from `main.iv`:

```iv
use "math.iv".
```

Only `public` declarations cross that boundary. A private helper in `math.iv` is invisible to `main.iv`, even when both files belong to the same package. This makes the file boundary useful without requiring a second namespace declaration.

## The daily commands

`foo check` parses and checks without producing a runnable file. `foo build` produces the configured artifact. `foo run` builds and starts it. `foo test` discovers test blocks. `foo fmt` applies the sentence-aware formatter. `foo watch` repeats check or build after relevant source, manifest, or dependency changes. `foo graph` prints discovered compilation units and their imports.

When a command fails, begin with the short diagnostic. Add `--verbose` for codes and compiler detail, or `--json` when another tool will consume the result.

## A complete small program

```iv
use io.

function greet(name of type text) of type nothing {
  display "Hello, " plus name.
  give nothing.
}

start() {
  constant name is read line.
  greet(name).
  give nothing.
}
```

`use io.` makes input and output available. `read line` produces text. `greet` receives it and returns `nothing` because its purpose is the display.

## When a check fails

FOO points at the part it cannot understand:

```text
main.iv:2:18

  constant count is "ten".
                   ^^^^^
  This value is text, but count needs an integer.
  Try: constant count is 10.
```

Fix the first useful error, then run `foo check` again. `foo watch` keeps running after an error and checks again when you save.
