# Changelog

All notable changes to FOO are documented here. Entries describe observable
behavior, compatibility, or material implementation changes.

## 1.0.0 - 2026-10-22

### Added

- Added QBE builds for hosted Windows x64, Linux x64, and Linux ARM64 in dev
  and release modes, with separate target gates for freestanding ELF, UEFI,
  WASI, threads, and SPIR-V products. See [target support](docs/qbe.md) for
  qualified behavior and limits.
- Added checked 1-128-bit integer operations, typed JSON runtime paths, hosted
  synchronization primitives, and freestanding volatile and atomic helpers.
- Added `project.ivc` configuration, project capabilities, deterministic
  `foo config emit`, and `.ivl` dependency locks.
- Added QBE build metadata that records target, mode, policy, tool identities,
  and runtime input hashes for cache identity.
- Added regional test commands and target gates for the active compiler route.
- Bundled native ARM64 QBE, TinyCC, a static assembler, and musl support in the
  Linux ARM64 release package.

### Changed

- Made QBE the active backend for build, run, test, benchmark, and release
  commands.
- Grouped benchmark workloads, controls, and feature inputs by purpose.
- Updated package discovery, registry pages, editor syntax, and documentation
  for the active project and compiler formats.

### Fixed

- Fixed persistent heap insertion changing storage shared with an older heap
  value.
- Preserved named argument labels on explicit generic calls and rejected
  positional arguments after named ones.
- Improved release staging checks for support-path collisions and output
  hashes.

### Removed

- Removed the retired compiler backends and their backend-specific test routes.
- Removed legacy JSON project manifests and lockfile fallbacks; projects use
  `project.ivc` and package commands write `.ivl` locks.
- Removed automatic toolchain provisioning from normal builds and the Debian
  installer. Setup now uses explicit bootstrap commands.

### Compatibility

- **Breaking:** `--backend` and `build.backend` accept only `qbe`. Remove an
  old backend selection or set it to `qbe`, then check [target support](docs/qbe.md).
- **Migration:** Convert earlier JSON project manifests to `project.ivc` and
  use `foo.ivl` for dependency locks.
