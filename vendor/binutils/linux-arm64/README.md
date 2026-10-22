# AArch64 assembler

`qbe-as-arm64` is a static AArch64 GNU assembler built from Ubuntu's
`binutils-source` package 2.38-4ubuntu2.12. The source package SHA-256 is
`8893ca8f5b87a4e13012ec7a824fcc15ed974a183d6e69d2ce5456897258cddb`.
`tools/binutils/linux/build.mjs` reproduces the build with the pinned managed
Zig toolchain. It builds only GNU `as`, disables shared libraries and the
unused Binutils programs, and strips the result. The build uses Zig only to
produce the assembler; Zig is not part of the released compilation pipeline.

The source package can be obtained from Ubuntu's `jammy-updates` repository.
The adjacent `COPYRIGHT` file carries its distribution notices.
