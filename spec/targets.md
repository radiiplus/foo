# Target System (MVL-1)

Targets are resolved by the toolchain resolver. Users specify simple presets; the resolver expands them to full triples and CPU features.

## Preset Strings
- `linux` (defaults to `x86_64-linux-gnu`)
- `linux-musl` (defaults to `x86_64-linux-musl`)
- `darwin` (defaults to `aarch64-macos`, or `x86_64-macos` based on host)
- `windows` (defaults to `x86_64-windows-msvc`)
- `wasi` (defaults to `wasm32-wasi`)
- `freestanding` (defaults to `aarch64-freestanding`, for embedded)

## Advanced Target Object
For precise control, the preset can be replaced by an object in `config.json`:
```json
{
  "arch": "x86_64" | "aarch64" | "riscv64" | "wasm32",
  "os": "linux" | "darwin" | "windows" | "wasi" | "freestanding",
  "abi": "gnu" | "musl" | "msvc" | "none",
  "cpu": {
    "model": "string",
    "features": ["+avx2", "-bmi"]
  },
  "glibc": "2.17" 
}
```
*Note: The `glibc` key is critical for cross-compilation, allowing pinning to older ABI versions without requiring a host sysroot.*