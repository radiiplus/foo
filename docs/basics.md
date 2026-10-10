# FOO Basics

What can you do with an empty FOO file? Add one statement and you have a
program you can run. Every complete example here can go in `src/main.iv`;
run it with `foo run`.

## Your first statement

```foo
display "Hello, world!".
```

Output:

```text
Hello, world!
```

`display` writes text to standard output. The final dot ends the statement. FOO
does not require a `start` function for ordinary top-level code.

Read one line from standard input with the high-level `input` operation. It
is failable because an input stream can fail:

```foo
constant name is input fallback "friend".
display "Hello, " plus name.
```

Use the `io` module only when you need an explicit stream, bounded reads, or
error handling for writes.

Use `report` for diagnostic text sent to standard error:

```foo
report "Configuration is missing".
```

The complete high-level console surface is `input`, `display`, and `report`.
They map to standard input, standard output, and standard error respectively.
Explicit stream code uses `io.input`, `io.output`, `io.report`,
`io.read`, `io.line`, `io.write`, and `io.close`.

## Statements and blocks

A statement performs one complete action and ends in a dot. A block groups
statements between braces.

```foo
constant signed is true.

when signed {
  display "Welcome back".
}
```

Do not add a dot after a closing brace. The statements inside the block still
need their own dots.

## Top-level code and `start`

Use top-level statements for scripts and small applications:

```foo
display "Preparing report".
display "Report ready".
```

Use `start` when an application benefits from an explicit entry function:

```foo
start {
  display "Service started".
}
```

Both forms are valid. Reaching the end of `start` completes automatically;
`give nothing.` is unnecessary.

## Comments

Use two hyphens for one line and three hyphens around a block.

```foo
-- This comment ends at the next line.
display "Visible".

---
This is a block comment.
It may cover several lines.
---
```

Comments explain intent. They are ignored by the compiler.

## Files and commands

A generated application begins like this:

```text
my-app/
|-- project.json
|-- src/
|   `-- main.iv
|-- test/
|   `-- main.iv
|-- benchmark/
|   `-- main.iv
`-- assets/
    |-- icon.ico
    `-- icon.svg
```

Run these commands from the directory containing `project.json`:

| Command | What it does |
| --- | --- |
| `foo check` | Checks syntax and types without building an executable. |
| `foo run` | Checks, builds, and runs the default entry. |
| `foo build` | Builds without running. |
| `foo link` | Links the default entry as a direct user command. |
| `foo release` | Stages an optionally configured deployment release. |
| `foo test` | Discovers, compiles, and runs the project's test blocks; no matches is an error. |
| `foo benchmark` | Measures the benchmark programs. |

Use `foo check` while learning. It gives the shortest path from a mistake to a
useful diagnostic.

## Try it

1. Replace `src/main.iv` with two `display` statements.
2. Run `foo check`.
3. Run `foo run` and confirm the two messages appear in order.
4. Remove one final dot, run `foo check`, and read the highlighted location.
5. Put the dot back before continuing.

## Common mistakes

| Problem | Fix |
| --- | --- |
| `expected '.'` | End the statement with a dot. |
| `unexpected token '}'` | Check the statement immediately before the brace. |
| `project.json not found` | Run the command from the project directory. |
| A failable call is rejected | Add postfix `try` or provide a `fallback`. |

Next: [Variables](variables.md).
