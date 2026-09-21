# Toolchain

Version: 1. Installation manifest format: `foo.install`.

Installing FOO provides the `foo` command on PATH and a complete base
installation for the selected host. Base users do not separately install
machine toolchains, assembler packages or a particular system compiler.
Required native-generation components are managed by FOO at exact versions.

FOO uses one compiler, implemented in TypeScript and distributed as JavaScript.
It supports the C11 and Zig backends. Self-hosting is deferred.

## Capability levels

Levels are strictly ordered and cumulative:
**base < system < machine < hardware**.
A level includes every capability below it and the additions in its row.

| Level | Added capabilities |
| --- | --- |
| base | Source reading/parsing, type checking, ordinary records/choices, generics, errors, scope arenas, portable library APIs, normal native output, packages, formatting, testing and diagnostics |
| system | Explicit Allocator values, memory lifetime primitives, unsafe raw-memory access, FOO/foreign ABI interfaces, C declarations and header interfaces, processes, platform-specific system APIs, threads and atomics |
| machine | Assembly authoring through native interfaces, register access, architecture primitives, intrinsics and freestanding machine execution |
| hardware | Device interfaces, memory-mapped I/O, volatile device registers, interrupts, packed hardware layouts and SIMD authoring |

These levels authorize APIs and authoring features. They do not classify the
hidden machinery required to produce an ordinary executable. The trusted base
runtime and portable library services remain usable at base even when their
platform implementation needs native instructions.

An installation at a higher level can build lower-level projects without
granting those projects additional source capabilities. A target must also
support each operation. A hardware installation does not imply every device,
instruction set or target runner exists.

## Manifest

```json
{
  "format": "foo.install",
  "version": 1,
  "language": "1",
  "backend": "0.16.0",
  "host": "linux-x64",
  "level": "base",
  "components": [
    {
      "name": "compiler",
      "path": "/opt/foo/.artifacts/toolchain/0.16.0/zig",
      "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
```

The path and digest above are illustrative. Manifests record the exact backend
release, Node platform/architecture host identity, granted level and component
paths with SHA-256 content digests. They are stored under
`.artifacts/toolchain/capabilities`. Changed or missing components cannot grant
their recorded capability. A compatible existing managed compiler grants base.

System installation compiles a C11 atomic/header probe and records the managed
headers. Machine installation also compiles an assembly probe and records the
integrated assembler. These tools share the pinned distribution; they are not
unnecessarily downloaded a second time. Capability receipts validate the
compiler and recorded component files, not a complete extracted-file inventory.
The download installer separately verifies the release archive checksum.

## Installation behavior

`foo toolchain install base|system|machine|hardware` installs or verifies a
level. `foo toolchain` reports the available level. `foo install` selects the
project's declared level and installs its package dependencies. A capability
receipt is published only after its probes succeed. Failure leaves previous
valid levels available. Builds check `requires` before project tasks and native
compilation. Missing levels report the exact installation command.

Hardware setup verifies device authoring tools and registers a QEMU simulator
found on PATH or selected by `FOO_SIMULATOR`. Automatic simulator downloads are
not provided. If no simulator is available, hardware installation fails without
granting that level. Base, system and machine installations do not need QEMU.

On Windows, hardware-level installation and builds require WSL 2. Run
`wsl --install`, finish Linux distribution setup, then install and run FOO
inside that distribution. Windows and Linux capability receipts are separate;
an installed Windows compiler is not a Linux toolchain. Native Windows supports
base, system and machine levels. This is FOO's supported hardware workflow,
not a claim that Windows cannot run emulators.

On Ubuntu/Debian, install the device simulators with
`sudo apt-get install qemu-system-arm qemu-system-misc`, then run
`foo toolchain install hardware` from the Linux terminal. `foo doctor` reports
the Windows host restriction or the missing Linux simulator. Hardware setup
does not enable Windows features, restart the computer, or install privileged
Linux packages automatically. See [Microsoft's WSL installation guide](https://learn.microsoft.com/en-us/windows/wsl/install)
and [QEMU's installation instructions](https://www.qemu.org/download/).

Components may be fetched on demand instead of bundled into every installation.
Foreign libraries and target support packages are managed through declared
dependencies; the installer never guesses a library from its filename alone.
Cross-compilation support and executing a target binary are separate capabilities:
a runner is needed only for execution.

`foo doctor` reports the backend release, available level and missing project
requirements. Its JSON output has
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
