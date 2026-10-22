# FOO
Version: 1.

FOO is a systems language with sentence-like declarations, explicit effects and file-based namespaces. Source files use `.iv`; the command is `foo`. A period ends a simple statement. FOO file stems, variables, types, and functions use one meaningful word. Names do not join words with capitals, underscores, or spelling them together. Types begin with a capital letter; other names use lowercase. Foreign ABI symbols retain their platform-defined spelling.

These documents define FOO v1 conformance. A specification requirement is not a claim that every compiler release supports it. A release must identify unsupported constructs and reject them clearly.

## Language
| Contract | Reference |
| --- | --- |
| Tokens, productions and binding rules | [Grammar](grammar.md) |
| Canonical types, conversions and constraints | [Types](types.md) |
| Scope arenas, allocators and raw access | [Memory](memory.md) |
| Persistent sequence representation and ownership | [Sequences](sequences.md) |
| Failable values, propagation and cleanup | [Errors](errors.md) |
| File namespaces, visibility and dependencies | [Packages](packages.md) |
| Tasks, synchronization and lifetimes | [Concurrency](concurrency.md) |
| Portable library boundaries | [Library](library.md) |
| Foreign and native interfaces | [Native](native.md), [ABI](abi.md) |

## Toolchain
| Contract | Reference |
| --- | --- |
| Typed representation and substrate boundaries | [IR](ir.md) |
| Configuration source and capability schema | [Configuration](configuration.md) |
| Project configuration and dependency lock | [Project](project.md) |
| Installation levels and compiler service | [Toolchain](toolchain.md) |
| Presets and target descriptors | [Targets](targets.md) |
| CPU selection, equivalence and performance | [Optimization](optimization.md) |
| Human and machine diagnostics | [Diagnostics](diagnostics.md) |
| Tests, formatting and editor behavior | [Testing](testing.md) |
| Application benchmark discovery and measurement | [Benchmarking](benchmarking.md) |
| Removed duplicate spellings | [Consolidation](consolidation.md) |

Each contract states its own version independently of an application's release
version. Filenames describe their subject without embedding a version or
development milestone. These contracts define intended behavior; the
[current support guide](../docs/status.md) and [QBE target guide](../docs/qbe.md)
identify which products and services have passed implementation gates.

The compiler accepts source through a library interface: parsing, semantic
analysis, and typed FOO IR precede QBE lowering for native output. WAT and
SPIR-V products use their target-specific lowering routes. The CLI presents
this service. Target choice does not change ordinary FOO syntax or library
types. See [current support](../docs/qbe.md) for qualified routes.
