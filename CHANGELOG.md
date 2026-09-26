# Changelog

All notable FOO compiler, language, standard-library, tooling, and distribution
changes are recorded here.

## 0.3.0 - 2026-09-26

### Build Performance

- Share Zig compiler caches across projects so subsequent builds can reuse
  backend work instead of starting cold in every project directory.
- Use Zig's faster self-hosted backend for compatible development builds and
  retain the full backend for optimized or incompatible programs.
- Compile and link simple C applications in one invocation, and compile native
  sources concurrently when the compatibility path is required.
- Select parallel job counts from available CPU and memory while reserving
  system headroom, with additional resources assigned to slower build paths.
- Report project artifact reuse explicitly and avoid rebuilding unchanged
  applications.

### Operation Interface

- Give check, build, run, install, update, remove, publish, and toolchain
  commands one consistent staged terminal interface.
- Show live activity, timestamps, elapsed time, source files, worker counts,
  cache reuse, meaningful stage results, and concise completion summaries.
- Keep the default display quiet and readable, reserve `100%` for completed
  work, and add `--explain` for deeper diagnostic detail without changing
  machine-readable `--json` output.
- Adapt stage layouts and color output to terminal width and capability.

### Runtime And Backends

- Add a Zig-native basic I/O path for display, input, line, read, write, and
  close operations so simple applications do not need the hosted C service.
- Download the managed Zig toolchain through WinHTTP and the Windows
  certificate store, keeping native Windows installs independent of OpenSSL.
- Add a shared live command runner for compiler processes, including responsive
  activity updates and accurate duration reporting.

### Documentation And Quality

- Document fast and compatibility build paths, adaptive resource use, cache
  behavior, the operation interface, and the `--explain` workflow.
- Exclude local standard-library build caches and test executables from the npm
  release archive while retaining the shipped test sources.
- Keep platform distributions isolated from stale native binaries produced for
  other operating systems or architectures.
- Expand tests for C fast-path execution, Zig-native I/O, build selection,
  terminal output, and service requirements.

## 0.2.3 - 2026-09-26

### Toolchain Setup

- Show the selected Zig release, target platform, install destination, total
  archive size, downloaded bytes, percentage, and transfer rate.
- Report checksum verification, archive inspection, extraction, installation,
  and executable verification as distinct stages.
- Stream native toolchain downloads directly to disk before checksum
  verification.
- Use the same detailed progress language for native and npm installations.

## 0.2.2 - 2026-09-25

### Installation

- Add a dedicated Windows Start Menu uninstaller while retaining removal from
  Windows Installed Apps and automatic cleanup of the installer-added PATH.
- Remove the system-managed Zig backend during Debian package removal as well
  as purge, without touching projects or per-user FOO configuration.
- Document the supported uninstall paths on the website and in the setup guide.

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
