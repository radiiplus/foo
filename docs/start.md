# Getting Started

In a few minutes, you can run a FOO program that prints a message. This chapter
takes you from checking the installation to editing that first line.

---

## Check the installation

Download the package for your platform from the [FOO releases](https://github.com/radiiplus/foo/releases).
Windows has an installer; Debian and Ubuntu have x64 and ARM64 packages. See
[Platforms](platforms.md) for the supported targets.

Open a terminal and check the installed toolchain:

```sh
foo doctor
```

`foo doctor` reports whether the tools needed to build a project are ready.

---

## Create a project

Create a project named `hello`:

```sh
foo new hello
cd hello
```

The program you will edit is in `src/main.iv`.

---

## Write one statement

Open `src/main.iv` and replace its contents with:

```foo
display "Hello, vibes!".
```

`display` writes a value to standard output. The quoted text is the message.
The final period ends the statement. That is a complete FOO program; functions
and named values come in later lessons.

---

## Run it

From the project folder, run:

```sh
foo run
```

You should see:
```text
Hello, vibes!
```

Change the text in `src/main.iv` and run `foo run` again. You can now move on to
[FOO Basics](basics.md), or explore what the project generated.

## Explore your project

The generated project has separate places for application code, tests, and
benchmarks:

```text
hello/
|-- src/
|   `-- main.iv
|-- test/
|   `-- main.iv
|-- benchmark/
|   `-- main.iv
|-- project.json
`-- .gitignore
```

The `.iv` extension marks FOO source. `project.json` names the entry file and
output directory:

```json
{
  "source": "src",
  "entry": "src/main.iv",
  "entries": {},
  "build": {
    "output": "output",
    "icon": "assets/icon.ico"
  }
}
```

`foo run` checks the project, builds a native executable through the selected C
or Zig backend, and runs it. Use `foo run --explain` when you want to see the
chosen build path and cache reuse.

### Installation details

The Debian installer provisions the pinned Zig backend. `foo run` and
`foo build` can retry that setup after an offline installation. On Debian and Ubuntu,
the C backend also provisions dependencies for the bundled `crypto`, `compress`,
and `http` modules. Clang is optional unless a project imports C headers.

For Ubuntu through Termux/proot on ARM64 Android, check that `uname -m` prints
`aarch64` inside Ubuntu and install `foo-arm64.deb` there. The package targets
Ubuntu's glibc environment and does not run directly in Termux.

On Windows, uninstall FOO from **Settings > Apps > Installed apps**. On Ubuntu
and Debian, run `sudo apt remove foo`. Uninstalling leaves projects and `~/.foo`
user data in place.

### Adding another runnable program

Suppose the same project also has `src/worker.iv`. Give it a short command name
in `project.json`:

```json
{
  "source": "src",
  "entry": "src/main.iv",
  "entries": {
    "worker": "src/worker.iv"
  }
}
```

Now the commands are unambiguous:

```sh
foo run          # runs src/main.iv
foo run worker   # runs src/worker.iv
```

Each named entry is an ordinary FOO program. Use a short, memorable name; the
path stays in `project.json`, so nobody has to remember it.

---

## Add a second file

When an operation is useful in more than one file, put it in its own module.
The module controls which names other files can see.

Create `src/math.iv` beside `src/main.iv` (inside the `hello` project) and add
this:

<!-- snippet: project math src/math.iv -->
```foo
public function add(left integer, right integer) {
  give left plus right.
}
```
`public` makes `add` available to other modules. Without it, the function stays
private to `math.iv`. FOO infers the result type from `give` here.

Replace the contents of `src/main.iv` with this program. The relative import
`"math.iv"` finds `src/math.iv` because the two files are in the same folder:

<!-- snippet: project math src/main.iv -->
```foo
use "math.iv" as math.

constant total is math.add(10, 20).
display total.
```

From the `hello` project folder, run `foo run`. It prints `30`. `display` uses
the standard codec to convert the integer to text; no extra import is needed.

---

## Find a type error

What if you give an integer name a text value? The compiler points to the
mismatch before you run the program.

Try this deliberately invalid declaration:

<!-- snippet: error TypeMismatch -->
```foo
constant age of type integer is "twenty".
```

Run `foo check`. The compiler reports a `TypeMismatch` at `"twenty"`: the
annotation requires an integer, but the initializer is text. Replace it with an
integer such as `20`, then check again.

The official VS Code extension can do this check while you type. It starts
`foo lsp` automatically and places errors directly on the affected code. This
is different from `foo watch`: the language server powers editor diagnostics,
hover information, and go-to-definition, while `foo watch` continuously builds
the project in a terminal. If VS Code cannot find the compiler, set **FOO:
Server Path** to the `foo` executable.

---

## Commands to keep nearby

These commands cover the usual edit, check, and run cycle:

*   **`foo check`**: Parses and type-checks the project without running it.
*   **`foo build`**: Builds an application without running it.
*   **`foo run`**: Builds and runs the application.
*   **`foo test`**: Runs the checks under `test/` and any test blocks in the project.
*   **`foo benchmark`**: Builds each program under `benchmark/` once, warms it up, and reports repeated timings.
*   **`foo watch`**: Rechecks and rebuilds when project files change.
*   **`foo fmt`**: Rewrites source using the canonical FOO formatting rules.

---

Continue with [FOO Basics](basics.md) for values, decisions, loops, and more
small programs.
