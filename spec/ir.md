# Intermediate Representation (MVL-1)

The IR is typed, SSA-based, and strictly backend-agnostic. It is the sole contract between the frontend and any backend (Zig, C, LLVM, Native).

## Core Instructions
- `alloc <region>, <type>, <count>`: Allocates memory in a specific arena region.
- `load <ptr>` / `store <ptr>, <value>`: Memory access.
- `call <func>, <args...>`: Function invocation.
- `branch <cond>, <true_block>, <false_block>`: Control flow.
- `phi <block1>: <val1>, <block2>: <val2>`: SSA state merging.
- `panic <message>`: Unrecoverable failure edge.
- `try <value>, <error_block>`: Error union unwrapping. If error, jumps to `<error_block>` with the `Error` value in a dedicated register.
- `defer <block>`: Registers a cleanup block for scope exit.
- `atomic_load <ptr>, <order>` / `atomic_store <ptr>, <value>, <order>`: Concurrency primitives.
- `extern_decl <name>, <signature>`: FFI boundary marker.

## Metadata
- **Alloc-Regions**: Every `alloc` instruction is tagged with a region ID (e.g., `scope_1`, `heap_explicit`). The backend uses this to select the correct allocator.
- **Error-Trace Slots**: Instructions that can fail (e.g., `call` to a `!T` function) have an attached slot for the compiler to inject source location data in `dev` mode.
- **Eval Residue Tables**: Compile-time evaluated constants are stored in a separate, immutable table. The IR references them by ID, ensuring zero runtime cost.