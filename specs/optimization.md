# Optimization

Version: 1.

Optimization preserves FOO's observable behavior, including errors, arithmetic
checks, effect order, atomic ordering and overlapping memory copies. Source
spelling or visual similarity is not evidence of equivalence.

Release builds may share equivalent private functions, remove unused pure
computations and inline calls within a cost budget. The budget accounts for
operation cost and the selected architecture. Public and address-taken functions
retain their identity. Development builds may enable semantic optimization with
`build.semantic`; release builds enable it by default.
Costs are relative estimates, not cycle counts or measurements of a specific CPU.

`foo build -mcpu x86-64-v3` selects a CPU profile. The equivalent persistent
setting is `build.cpu` in `project.json`. A command-line choice overrides that
setting; otherwise the target preset supplies the CPU. The architecture must
match the selected target. These choices do not change FOO syntax.

| Profile | Relevant instruction support |
| --- | --- |
| x86-64 | SSE, SSE2 |
| x86-64-v2 | SSE through SSE4.2 |
| x86-64-v3 | AVX, AVX2, FMA |
| x86-64-v4 | AVX-512 F, BW, DQ, VL |
| arm64 | NEON |
| apple_m1 | Apple M1, NEON |
| arm64-sve | NEON, scalable vectors |
| rv64g | Integer, multiplication, atomic and floating-point operations |
| rv64gcv | RV64G with compressed instructions and scalable vectors |

`baseline` selects the architecture's baseline profile. A vector-capable target
allows vector instructions; it does not require every operation to use them.
Scalable vectors have no fixed width. The `linux-x64-v3` and `windows-x64-v3`
presets select v3; ordinary x64 presets retain baseline requirements.

Optimized copies choose an implementation using the target, CPU, capability
level, optimization mode and portable-substrate override. Every choice preserves
the same bounds and overlap behavior. Choosing a CPU is a deployment promise:
the executable is only required to run on processors supporting that profile.
Cross-compilation does not execute the selected instructions on the build host.

CPU, target, optimization settings and compiler contents participate in generated
output cache identities. A CPU change invalidates affected compiled output.
Unchanged source parsing can still be reused. No optimization choice alone
guarantees a speedup; performance claims require measurements on the target.

Instruction levels follow the compiler target definitions for
[x86](https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html),
[AArch64](https://gcc.gnu.org/onlinedocs/gcc/AArch64-Options.html) and
[RISC-V](https://gcc.gnu.org/onlinedocs/gcc/RISC-V-Options.html).
