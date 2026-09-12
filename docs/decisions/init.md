# Memo: Init

## Status
Accepted

## Context
We are building `tratio` (`.rt`), an independent systems programming language. We must prevent backend complexity from leaking into the language design, standard library, or user tooling.

## Decision
1. **Naming**: The language is `tratio` with the `.rt` extension.
2. **Stack**: 
   - Typescript for the compiler frontend, tooling, and package manager.
   - Wasm for portable execution of the compiler.
   - Zig (pinned to v0.16.0) strictly as a generation backend.
3. **Architecture**: The compiler is a library (`core`) with a thin cli wrapper (`driver`). 
4. **Boundary**: A single `Emitter` module in Typescript is the **only** place Zig concepts are allowed. It consumes a stable `Module` (v1) and emits Zig code.
5. **Configuration**: User projects are defined exclusively via `project.json` (v1 schema). No user scripting language is permitted in v1.
6. **Testing**: Snapshot testing is mandatory for all compiler pipeline stages.

## Consequences
- Strict isolation ensures `tratio` can eventually swap out the Zig backend for C, LLVM, or native without breaking user code.
- Requires rigorous reviews to prevent Zig-specific terminology from appearing in `core` or `library` public apis.