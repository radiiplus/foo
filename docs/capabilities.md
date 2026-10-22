# Systems Capabilities

FOO distinguishes `base`, `system`, `machine` and `hardware` capability levels.
The requested level authorizes APIs; target support determines whether a given
operation can be lowered. Unsupported target and capability combinations must
receive a diagnostic.

The current implementation includes QBE native builds, direct WAT for WASI,
and SPIR-V shader products. Details of aggregate ABI, atomics, native
operations, cleanup and freestanding target support are in
[QBE Backend Support](qbe.md). The language contracts are in
[`specs/toolchain.md`](../specs/toolchain.md) and
[`specs/targets.md`](../specs/targets.md).
