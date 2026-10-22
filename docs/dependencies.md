# Build Dependencies

FOO builds hosted native programs through QBE and TinyCC. Their compiler
sources live in `vendor/qbe` and `vendor/tcc`. The release toolchain
assets are listed in [`toolchain/assets.json`](../toolchain/assets.json); the
selected tool and runtime identities are recorded in each `.qbe.json` build
receipt. WebAssembly builds require WABT `wat2wasm`. Shader validation uses
the bundled SPIR-V tools.

Native C inputs, libraries, headers, linker scripts and vendor archives must
match the requested target. `foo doctor` reports missing build inputs without
installing them. Vendored input hashes are checked against
[`vendor/manifest.json`](../vendor/manifest.json). See [QBE Backend Support](qbe.md)
for target-specific limits and qualification gates.
