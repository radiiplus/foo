# FOO
Version: 1.

FOO is a systems language with sentence-like declarations, explicit effects and file-based namespaces. Source files use `.iv`; the command is `foo`. A period ends a simple statement. Public names use meaningful single words where their meaning remains clear.

These documents define FOO v1 conformance. A specification requirement is not a claim that every compiler release supports it. A release must identify unsupported constructs and reject them clearly.

## Language
| Contract | Reference |
| --- | --- |
| Tokens, productions and binding rules | [Grammar](grammar.md) |
| Canonical types, conversions and constraints | [Types](types.md) |
| Scope arenas, allocators and raw access | [Memory](memory.md) |
| Fallible values, propagation and cleanup | [Errors](errors.md) |
| File namespaces, visibility and dependencies | [Packages](packages.md) |
| Tasks, synchronization and lifetimes | [Concurrency](concurrency.md) |
| Portable library boundaries | [Library](library.md) |
| Foreign and native interfaces | [Native](native.md), [ABI](abi.md) |

## Toolchain
| Contract | Reference |
| --- | --- |
| Typed representation and substrate boundaries | [IR](ir.md) |
| Project configuration and dependency lock | [Project](project.md) |
| Installation levels and compiler service | [Toolchain](toolchain.md) |
| Presets and target descriptors | [Targets](targets.md) |
| CPU selection, equivalence and performance | [Optimization](optimization.md) |
| Human and machine diagnostics | [Diagnostics](diagnostics.md) |
| Tests, formatting and editor behavior | [Testing](testing.md) |
| Removed duplicate spellings | [Consolidation](consolidation.md) |

Each format carries version 1 independently of an application's release version. Filenames describe their subject without embedding a version or development milestone.

The compiler accepts source through a library interface: parsing, semantic analysis and typed FOO IR precede lowering through the C substrate and ASM substrate to native output. The CLI presents this service. Substrate choices do not change ordinary FOO syntax or library types.
