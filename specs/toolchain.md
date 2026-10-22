# Toolchain

Version: 1.

The FOO compiler is implemented in Nim and lowers typed IR through QBE for
native targets. WebAssembly products use direct WAT emission and WABT;
shader products use SPIR-V. The selected assembler, linker, target SDK and
native libraries must match the requested architecture and ABI.

## Capability levels

Levels are strictly ordered and cumulative:
**base < system < machine < hardware**.
A level includes every capability below it and the additions in its row.

| Level | Added capabilities |
| --- | --- |
| base | Source reading/parsing, type checking, ordinary records/choices, generics, errors, scope arenas, portable library APIs, normal native output, packages, formatting, testing and diagnostics |
| system | Explicit Allocator values, memory lifetime primitives, verified native memory interfaces, FOO/foreign ABI interfaces, C declarations and header interfaces, processes, platform-specific system APIs, threads and atomics |
| machine | Assembly authoring through native interfaces, register access, architecture primitives, intrinsics and freestanding machine execution |
| hardware | Device interfaces, memory-mapped I/O, exact device access, interrupts, packed hardware layouts and SIMD authoring |

These levels authorize APIs and authoring features. They do not classify the
hidden machinery required to produce an ordinary executable. The trusted base
runtime and portable library services remain usable at base even when their
platform implementation needs native instructions.

A project requesting a higher level may use lower-level APIs, but each target
must also support the requested operation. Declaring hardware capability does
not imply every device, instruction set or target runner exists.

## Selection and identity

`foo toolchain` reports the selected QBE and C tools and checks their
identities. Release assets are declared in `toolchain/assets.json` and build
receipts contain selected tool hashes. `FOO_QBE`, `FOO_QBE_TCC`, and
`FOO_WAT2WASM` select explicit tools where needed. The Linux x64 release asset
bundles target-specific TinyCC, musl sysroots, assemblers and linkers for its
qualified native routes. `FOO_QBE_CC`, `FOO_QBE_LINKER`, and target sysroot
overrides may select compatible external tools. Tool choice and input hashes
participate in the build identity; no Zig compiler is required for QBE output.

## Installation behavior

`foo install` resolves project package dependencies. Project capability names
are `base`, `system`, `machine` and `hardware`; an unknown name is rejected, and
Windows hardware projects require WSL 2. Target availability is checked
separately. There is no managed capability-level installer or receipt in the
current QBE path.

Qualified Windows x64 builds use controlled static libsodium and zlib inputs.
Linux native dependencies are provided by verified vendor archives or the
target OS; missing inputs fail with a diagnostic. `foo doctor` checks these
dependencies without provisioning packages.

Hardware execution requires a compatible device or simulator. Target
cross-compilation and running the result are separate gates.

On Windows, hardware-level projects require WSL 2. A Windows host toolchain
does not supply a Linux target SDK or runner.

Foreign libraries and target support packages are explicit dependencies. A
runner is needed only for execution, not for producing a target artifact.

`foo doctor` reports selected QBE tools, project native inputs, target SDKs
and runners. It never installs packages or alters host configuration.
Its JSON output has
format `foo.doctor`, version 1, and component records with name, ready, required
and a human-readable reason. It must explain missing components without asking
base users to assemble a machine toolchain manually.

## Library and commands

The compiler is usable as a library. Its public operations accept source units,
configuration, dependency interfaces and explicit input providers, and return
versioned results and diagnostics. Library calls do not exit the host process,
change its working directory or write to its terminal. Output publication and
input access are controlled by the caller.

The CLI is a presentation and command-dispatch layer over that library.
It supplies `new`, `build`, `run`, `test`, `check`, `fmt`, `watch`, `graph`,
`add`, `remove`, `install`, `toolchain`, `clean`, `doctor` and `version`.
Build and check use the same language rules; watch changes scheduling, not
semantics. Commands must not claim success for unavailable capabilities.
