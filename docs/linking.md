# Linking and Native Inputs

The active native backend is QBE. Its driver selects target-specific assembly
and linking inputs, and records source, object, library, include and linker
script hashes in the `.qbe.json` artifact metadata. A library named only with
`-l` is resolved by the host linker and forces relinking on each build.

Hosted Windows and Linux, freestanding ELF, UEFI x64, WASI and shader products
have different link contracts. [QBE Backend Support](qbe.md) lists supported
products and current limits. The executable target gates live in
[`test/backend/qbe/TARGETS.md`](../test/backend/qbe/TARGETS.md).
