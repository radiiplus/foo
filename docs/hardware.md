# Hardware Targets

Freestanding x64, ARM64 and RISC-V products use QBE and target-specific
assembly and linking. The QBE driver supports explicit startup, setup-free
assembly, target features, volatile access, integer atomics and qualified
interrupt and exception forms. UEFI x64 has a separate PE32+ path.

These builds do not provide hosted allocation, filesystem or network services.
The board or firmware supplies startup, memory and device interfaces. Target
limits and tested QEMU/OVMF gates are in [QBE Backend Support](qbe.md) and
[`test/backend/qbe/TARGETS.md`](../test/backend/qbe/TARGETS.md).
