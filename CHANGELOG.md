# Changelog

All notable FOO compiler, language, standard-library, tooling, and distribution
changes are recorded here.

## 0.2.1 - 2026-09-25

### Tooling And Distribution

- Accept Zig archive sizes encoded as either JSON strings or numbers while
  retaining strict size and SHA-256 verification.
- Provision the pinned Zig backend during Debian installation and retry the
  managed installation on first use when initial setup was offline.
- Keep managed user toolchains under `~/.foo/toolchains` and detect toolchains
  bundled beside the installed FOO compiler.
- Clarify in `foo doctor` that Clang is not required unless a project imports C
  headers or selects an external C compiler explicitly.

## 0.2.0 - 2026-09-25

### Language

- Allow executable top-level statements, including `display`, without requiring
  an explicit `start()` function.
- Infer completion for functions that give `nothing`, removing routine
  `give nothing` boilerplate.
- Add concise parameter and result annotations while preserving explicit
  `of type` syntax where useful.
- Introduce the preferred vocabulary `define ... as`, `dynamic`, `stop`,
  `skip`, `fallback`, `multiply`, `subtract`, and `divide`.
- Move `try` after the operation it propagates, so `read() try` replaces the
  older `try read()` spelling in canonical source and formatted output.
- Add direct `greater than or equal to` and `less than or equal to`
  comparisons so positive conditions do not require `not` wrappers.
- Keep `fallible` for functions that may fail.
- Require native C source to live in an explicit native container so it cannot
  be confused with FOO code.

### Projects And Packages

- Generate application entry files under `src/` and support `foo new .` for
  initializing the current directory.
- Accept registry dependencies as `foo add package` or `foo add package@version`.
- Accept URLs and local paths for external dependencies without exposing
  internal registry locator syntax.
- Add semver-aware dependency selection, platform metadata, scalable registry
  indexes, package auditing, mirrors, deprecation, and clearer package errors.
- Add Rust-style checking, downloading, compiling, and completion progress to
  project builds.

### Standard Library And Runtime

- Prefer `file` over `fs` and expand file positioning, size, and flush controls.
- Replace snake-case standard-library functions with camel case, including
  `addHeader`, `clearHeaders`, `closeServer`, `sendSome`, `showMessage`, and
  `showError`.
- Add advanced HTTP header, redirect, connection-reuse, server, TCP shutdown,
  socket-policy, task, JSON, dynamic-library, atomic, and OS controls.
- Use WinHTTP and the Windows certificate store for the C HTTP backend, removing
  the external curl/OpenSSL requirement on Windows.
- Add mutable `hashmap`, sequence deduplication, and optimized map, filter,
  split, allocation, hashing, and byte-transfer paths.
- Standardize explicit optimized copying across the C and Zig runtimes while
  retaining portable fallbacks and target-aware substrate selection.

### Tooling And Distribution

- Update the formatter, diagnostics, documentation, examples, TextMate grammar,
  snippets, and editor fixtures for the current language.
- Add Linux ARM64 archives and Debian packages for native ARM Linux and Ubuntu
  running through Termux/proot.
- Validate staged ELF architecture before creating Debian packages.
- Shorten release asset names to platform-focused names such as
  `foo-arm64.deb` and `foo-windows-x64.exe`.
- Add a registry downloads page for Windows x64, Linux x64, and Linux ARM64
  release packages, with clean browser paths and legacy hash-link redirects.
  The compact view follows the latest published compiler release and identifies
  when the source version is newer and still awaiting publication.

## 0.1.0 - 2026-09-21

- First native FOO compiler release with project checking, formatting, testing,
  C11 and Zig output, the standard library, Windows x64, and Linux x64 packages.
