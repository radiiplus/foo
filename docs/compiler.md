# The Compiler

FOO parses source, checks types and effects, and lowers the result to typed IR.
The QBE backend emits native code for its qualified targets. WASI and
WebAssembly products use direct WAT emission and WABT; shader products use
SPIR-V emission and validation.

```sh
foo build --backend qbe --target windows-x64
foo build --backend qbe --target wasi
```

The target and mode choose ABI rules, runtime fragments and native inputs.
Build receipts record the lowering policy and input identities so cached
artifacts can be tied to those choices. `foo build --explain` reports selected
build decisions. See [QBE Backend Support](qbe.md) for qualified products and
limits, and [Build Cache](cache.md) for cache identity.
