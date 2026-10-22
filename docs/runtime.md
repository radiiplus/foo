# Runtime

The active backend is QBE. Public service contracts live in `lib/*.iv` and
native implementations live under `src/runtime/`. Hosted native programs link
the target's selected runtime fragments. Freestanding builds do not gain hosted
allocation, I/O, network or process services implicitly.

The WASI route emits imports directly for its qualified Preview1 operations and
threaded execution. Unsupported services receive diagnostics. Current runtime
coverage and target limits are tracked in [QBE Backend Support](qbe.md).
