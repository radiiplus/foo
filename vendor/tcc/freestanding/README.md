# Freestanding integer objects

These ELF relocatable objects contain only the integer section of
`src/runtime/qbe.c`. They are built with the vendored TinyCC source and have no
unresolved symbols. The QBE driver checks `manifest.json` against the runtime
source and object hashes before linking them.

On Linux x64 or WSL, run `node tools/tcc/freestanding/build.mjs` from
the repository root to rebuild all three targets. Set `FOO_QBE_TCC_BUILD` to an
existing build directory containing `tcc`, `arm64-tcc`, and `riscv64-tcc` to
reuse those compiler binaries.
Review and update the five `tcc/freestanding/` hashes in
`vendor/manifest.json` after rebuilding, then run `node tools/vendor/audit.mjs`.
