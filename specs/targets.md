# Targets

Version: 1. Advanced target schema: 1.

A target determines operating environment, address size, data layout, ABI and
available operations. A capability level grants permission; a target establishes
whether an operation exists. Both checks are required.

## Presets

| Preset | Architecture | Environment | ABI | Runtime |
| --- | --- | --- | --- | --- |
| linux-x64 | x64 | linux | gnu | hosted |
| linux-x64-v3 | x64, v3 | linux | gnu | hosted |
| linux-arm64 | arm64 | linux | gnu | hosted |
| linux-musl-x64 | x64 | linux | musl | hosted |
| linux-musl-arm64 | arm64 | linux | musl | hosted |
| windows-x64 | x64 | windows | msvc | hosted |
| windows-x64-v3 | x64, v3 | windows | msvc | hosted |
| windows-arm64 | arm64 | windows | msvc | hosted |
| macos-x64 | x64 | macos | darwin | hosted |
| macos-arm64 | arm64 | macos | darwin | hosted |
| wasi | wasm32 | wasi | wasi | hosted |
| wasi-threads | wasm32 | wasi | wasi | hosted, shared memory and atomics |
| wasm-freestanding | wasm32 | none | eabi | none |
| arm64-freestanding | arm64 | none | eabi | none |
| riscv64-freestanding | riscv64 | none | eabi | none |

A preset is a complete descriptor with baseline CPU and an explicit feature set.
All v1 presets are little-endian; x64/arm64/riscv64 use 64-bit pointers and
wasm32 uses 32-bit pointers. An unspecified build target selects the matching
host preset, never the first arbitrary installed target.

The wasi-threads preset has features `atomics` and `shared-memory`; wasi has
neither. The x64-v3 presets require the v3 instruction level. Other presets have an empty optional-feature list beyond their ABI's
baseline requirements. Deployment versions for each release's presets are fixed
in the installation's target catalog.

## Advanced descriptor

```json
{
  "schema": 1,
  "arch": "arm64",
  "os": "windows",
  "abi": "msvc",
  "runtime": "hosted",
  "endian": "little",
  "cpu": "baseline",
  "features": [],
  "minimum": "10.0"
}
```

Every field is required. Schema is integer 1. Arch is x64, arm64, riscv64 or
wasm32; os is linux, windows, macos, wasi or none. ABI/runtime pairs must match
a row in the preset table for that architecture. Runtime is hosted or none.
Endian is little in v1. CPU is baseline or a model in the versioned target
catalog. Features is a sorted, duplicate-free array of catalog feature names.

Minimum is a deployment version in the catalog's platform-specific version
format, or null for an environment with no deployment version.
Unknown features, unsupported versions and contradictory settings are errors.
No raw backend triple string substitutes for this descriptor.

A preset resolves to exactly one such descriptor before linking or caching.
Its resolved catalog version is recorded with the build identity. Changing the
catalog, target features or deployment minimum invalidates incompatible results.

The catalog is JSON with format `foo.targets`, version 1, an exact release
version, presets, models and features. Presets map each preset name to a complete
advanced descriptor. Models map an architecture and model name to its baseline
feature list. Feature records have name, architectures, requires and excludes;
requires and excludes contain feature names from the same catalog. Contradictory
or cyclic requirements are invalid. Preset deployment versions are numeric
dot-separated components compared numerically with omitted trailing components
treated as zero; environments without deployment versions use null.
The catalog's content digest, not its schema version alone, identifies its data.

## Output and execution

Hosted targets provide startup, root allocation and error reporting.
Runtime none requires machine capability and supplies no hosted services.
Its explicit start entry performs machine initialization through verified native
interfaces; device access additionally requires hardware capability.
A target never gains a libc or a system service merely because an API was named.

WASI binaries use their declared import interface. Shared-memory WASI additionally
requires system capability and a compatible runner. A freestanding binary has
no undeclared hosted imports. Foreign libraries must match architecture,
ABI, deployment minimum and required features.

Cross-compilation must not execute target code as part of ordinary evaluation.
`foo run` uses a matching local environment or an explicitly configured runner.
Missing runner support is reported separately from successful binary generation.
