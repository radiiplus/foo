# Tratio

Tratio is an experimental systems programming language with the `.rt` file
extension. The compiler frontend and tooling are written in TypeScript, use a
typed SSA intermediate representation, and currently generate Zig as the
backend target.

The project is under active development. Its syntax, APIs, and compiler stages
may change while the first language version is being defined.

## Requirements

- Node.js with npm
- Zig 0.16.x for backend tests and generated programs

## Setup

Install the JavaScript dependencies:

```sh
npm ci
```

Run the complete test suite:

```sh
npm test
```

The suite covers lexing, diagnostics, parsing, semantic analysis, type
checking, IR, Zig code generation, the standard library, package management,
and generics.

## Language Example

```rt
module example {
  type Point is record {
    x of type decimal 64.
    y of type decimal 64.
  }.

  function add(a of type integer 32, b of type integer 32) {
    give a plus b.
  }

  start() {
    constant answer of type integer 32 is add(20, 22).
    give.
  }
}
```

Tratio also has work in progress support for generic declarations and derived
operations:

```rt
module containers {
  #[derive(Eq, Hash)]
  type Box[T] is record {
    value of type T.
  }.

  function identity[T](value of type T) {
    give value.
  }
}
```

## Intermediate Representation

The compiler uses a backend-neutral, typed SSA representation. A small IR
module looks like this:

```text
module app {
  fn @add(%a: int, %b: int) -> int {
  entry:
    %1 = add %a, %b
    return %1
  }
}
```

The Zig backend turns this representation into a standalone generated module
and runtime shim. Keeping Zig details behind the emitter allows other backends
to be introduced without changing the language frontend.

## Repository Layout

```text
src/ast/          AST definitions and printing
src/diag/         Diagnostic codes, spans, and rendering
src/lex/          Lexer and token definitions
src/parse/        Source parser
src/sema/         Name and module resolution
src/types/        Type checking and safety analyses
src/ir/           IR model, parser, printer, validation, and monomorphization
src/backend/zig/  Zig emitter, runtime shim, and compiler driver
src/pkg/          Package resolution, cache, lockfile, and vendoring support
src/cli/          CLI workflows
src/lsp/          Language server support
std/              Tratio standard library modules
spec/             Language and compiler specifications
tests/            Stage-specific and integration tests
```

## Project Configuration

The current CLI reads `tratio.json`. A minimal configuration is:

```json
{
  "name": "myapp",
  "version": "1.0.0",
  "language": "1",
  "build": {
    "target": ["linux-x64"],
    "optimize": "dev"
  }
}
```

See [`spec/`](spec/) for the evolving language, type system, ABI, memory,
configuration, target, and IR contracts.
