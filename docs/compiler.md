# Compiler

The compiler is a native Nim program with a small JavaScript launcher for npm installations. It first breaks your text into words, understands the sentences, checks names and types, and prepares instructions for the chosen computer.

The compiler's private middle form records where values live, where errors can go, which operations must be indivisible, and whether a call crosses into C. A checker and printer make this middle form safe and repeatable.

Release builds may remove unused work, reuse a calculation made earlier, join identical safe functions, and place small functions directly at their call site. They do this only when the program's visible result stays the same. Watch builds remember file contents and imports, so a small edit does not rebuild unrelated files.

The backend selector chooses portable code, C, or target-specific assembly. C and Zig are implementation details managed by FOO; ordinary FOO code does not depend on either language. `-mcpu` and target names tell the compiler which computer it is preparing for.

## What happens during a build

First, FOO reads the files and recognizes words, numbers, strings, and punctuation. Next it groups those pieces into declarations and statements. It then checks that every name exists, every value has the right type, every imported name is public, and no value is used after its storage ends. Only after these checks does it make its middle instructions.

If one file imports another, the compiler checks the imported file first. A changed file causes that file and the files that depend on it to be checked again. A file that did not change keeps its saved result. This is why a large project can become quick after its first build.

## Build modes

`foo check` stops after checking. `foo build` continues to a native program. Development builds keep information that makes errors easy to understand. Release builds spend more time removing needless work and choosing faster instructions. Both modes must produce the same result.

## Reading compiler output

The normal output is short:

```text
main.iv:7:12

  display count.
           ^^^^^
  count is not defined
```

Use `--verbose` when working on the compiler itself. Use `--json` when an editor or another program needs exact locations and suggested fixes.

## Implementation languages

FOO source remains independent of the languages used to build the compiler. The implementation split is:

| Job | Language | Reason |
| --- | --- | --- |
| Compiler library and command | Nim | Small native distribution and simple systems access |
| Target-specific low-level pieces | Zig | Strong cross-compilation and safe low-level code |
| Tiny portable boundary pieces | C | C ABI and broad platform support |
| Downloads, packaging, tests, and watch helpers | JavaScript | Good file, process, and package automation |

The implementation lives under `src` and covers the lexer, diagnostics, parser, AST printer, imports, name and type checking, lifetime and match checks, FOO IR, optimization, C and Zig backends, native tool management, project builds, packages, formatting, tests, LSP, and the `foo` command. Its matching Nim tests live under `test`.

`npm run build` produces the distributable compiler in `.artifacts/compiler`, including `bin/foo.exe` for Windows and `bin/foo` for Linux when both platform builds are available. JavaScript handles launching, packaging, and managed toolchain installation; it is not part of FOO's language semantics.

```text
your .iv file -> understood FOO sentences -> checked instructions
              -> C, Zig, or machine instructions -> your program
```
