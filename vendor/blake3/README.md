# Bundled BLAKE3 C implementation

The C backend compiles the upstream BLAKE3 1.8.7 C sources from
https://github.com/BLAKE3-team/BLAKE3/tree/1.8.7/c alongside programs that
import `crypto`. The files are from commit
`f3149ec5bb5449af877ba20377a11008ff499fa2` and are licensed under
Apache License 2.0 (see `LICENSE_A2`).

The build includes the portable implementation, runtime dispatch, SSE2 on
x86-64, and NEON on AArch64. SSE4.1, AVX2, and AVX-512 are disabled in this
distribution. Other targets use the portable implementation.
