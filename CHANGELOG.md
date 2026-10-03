# Changelog

All notable FOO compiler, language, standard-library, tooling, and distribution
changes are recorded here.

## 0.7.1 - 2026-10-03

### Compiler And Libraries

- Emit JSON byte sequences as numeric arrays on both C and Zig backends,
  including nested records and choices, so encoded data transfers between
  backends without a format workaround.
- Provision the C backend's libsodium, zlib, and libcurl development files
  automatically on native Debian and Ubuntu builds when they are missing.
  Cache the packages without administrator access and include the libcurl
  runtime beside executables and in release bundles when needed.
- Have `foo doctor` verify or provision the C dependencies used by a project.
- Show toolchain download, verification, and installation progress during
  interactive setup, with periodic output when redirected.

## 0.7.0 - 2026-10-02

### Build And Release

- Rename the public product directory from `target/` to the language-neutral
  `output/` while retaining `.artifacts/` for compiler-owned intermediates and
  caches.
- Generate application icon assets with new projects and embed the configured
  `.ico` in Windows executables on both native backends.
- Add optional release staging with selected license, readme, icon, and extra
  files, versioned metadata, SHA-256 checksums, and opt-in GPG, Authenticode, or
  codesign executable signing without storing credentials in project files.
- Add named-entry command linking under the FOO user bin directory, with
  `foo path`, `foo link`, and `foo unlink` for direct commands that do not need
  the `foo` prefix.

### Packages

- Rename the bundled library directory and registry prefix from `std` to `lib`.
  Use `foo test lib` for its fixtures and `FOO_LIB` to override its location.
  Remove the old test selector, environment variable, and registry namespace so
  tooling exposes one unambiguous name.
- Install direct and transitive local path dependencies through `foo install`,
  derive their exact versions from their manifests, copy them into
  `.foo/packages`, and record normalized sources and content digests in
  `foo.lock`.
- Allow local and registry dependencies in the same project while preserving
  reachable locked registry versions and treating nested local paths relative
  to the package that declares them.

### Documentation And Testing

- Rewrite the project README around verified language capabilities, installation,
  project structure, everyday commands, packages, releases, editor support, and
  contribution paths.
- Render the README's FOO examples with the VS Code extension's TextMate grammar
  and token colors while retaining expandable, copyable source blocks.
- Add contributor, conduct, and security policies together with structured bug,
  feature, implementation-inconsistency, and pull request templates.
- Use backticks as the readable separator inside integer and decimal literals,
  limited to the whole-number portion. Preserve valid grouping through
  formatting, reject underscores and fractional separators with focused
  diagnostics, and align compiler tests, benchmarks, documentation, and editor
  highlighting.
- Make executable emission reachability-driven: retain entry points, exported
  ABI functions, and their transitive calls while excluding unused functions,
  runtime imports, native fragments, storage, and traces before C or Zig
  generation. Native service bridges are selected only for reached providers,
  and empty Zig programs no longer initialize unused allocator/library
  lifecycles.
- Enable function/data section collection for hosted C releases, select the
  native dead-code linker contract on GNU, Darwin, and MSVC targets, disable
  incremental/debug linker output in MSVC-targeted releases, and explicitly
  strip Zig release artifacts.
- Invalidate the native compiler cache when a C/Zig runtime fragment, service
  declaration, embedded manifest, or other `staticRead` input changes, avoiding
  stale generated backends without disabling ordinary Nim incremental builds.
- Add cross-backend generated JSON codecs for optional values, sequences, and
  choices, including nested record fields, checked C allocation, and end-to-end
  C and Zig regression coverage.
- Match Zig's optional-to-value equality in either operand order and its
  optional-to-value ordering behavior in generated C.
- Implement the public `arch.count`, `arch.pause`, and `arch.ticks` operations
  on the C backend for supported x86, ARM, and RISC-V targets.
- Bring hardware-target C emission to parity with Zig for explicit startup,
  setup-free and interrupt functions, checked target-feature clauses, runtime-free
  builds, common foreign calling conventions, WASI threads, and generated API
  documentation.
- Preserve exact-access hardware fields while parsing record and union members,
  so device pointer access reaches type checking and backend lowering.
- Replace Rust-shaped source attributes with FOO clauses: `for startup`,
  `for interrupt`, `without setup`, `using feature`, `keeping call`, and
  `with exact access`. Legacy attribute spellings remain input-compatible during
  migration, while formatting and documentation use the new forms.
- Align the public `arm64-freestanding` preset with its `aarch64` backend triple
  instead of passing the user-facing architecture name through unchanged.
- Compile native C fragments in runtime-free Zig builds without implicitly
  linking libc, while continuing to link it for hosted native interoperability.
- Keep verified assembly inline inside naked functions on both backends instead
  of lowering it to a forbidden helper call, enabling real boot entry bodies.
- Route C cross-builds for WASI and freestanding AArch64/RISC-V through the
  managed toolchain while preserving C11 source output, and verify the produced
  WebAssembly and ELF machine headers in backend tests. The Linux hardware gate
  now boots both C and Zig freestanding artifacts on the AArch64 and RISC-V QEMU
  boards.
- Represent every FOO integer width from 1 through 128 in C and generate
  width-specific checked arithmetic and JSON conversion instead of rejecting
  or truncating non-C-native widths.
- Specify the operating-system and filesystem boundaries of `file.sync` and
  `file.replace`, including the current one-writer and caller-supplied
  reclamation requirements.
- Add a local dependency regression covering transitive paths, installation,
  lock data, version resolution, and repeated installation.
- Run native tests through a CPU- and memory-bounded worker pool with isolated
  temporary directories, configurable job and timeout limits, and separate C
  cross-target, WASI, and threaded-WASI integration groups.
- Add equivalent handwritten Rust controls to every repository benchmark,
  including startup baselines, allocation telemetry, raw samples, and explicit
  per-workload Rust comparison ratios without making language-wide speed claims.
  Refresh the checked-in report with the v4 C, Zig, and Rust comparison.

## 0.6.1 - 2026-10-01

### Build System

- Publish completed applications, static libraries, and shared libraries to a
  project-local `target/` directory by default, with a safe `build.output`
  override and automatic directory creation.
- Keep backend source, objects, optimization reports, and cache metadata in
  `.artifacts/`, restore missing public products from cache, and exclude output
  directories from fingerprints and resource discovery.
- Avoid the Unix-only `-fPIC` flag when the C backend builds a Windows shared
  library.

### Editor

- Prepare VS Code extension 2.6.1 with statement-leading bare-call highlighting,
  dedicated failure/matching/cleanup scopes, qualified lowercase type scopes,
  rendered color assertions, and refreshed real-source snapshots.

### Documentation And Testing

- Explain selected-test paths and sibling/source-root import resolution at the
  testing workflow, backed by an execution test covering both import forms.

## 0.6.0 - 2026-09-29

### Language And Compiler

- Remove empty parentheses from zero-argument declarations, calls, function
  types, entry points, and generic specializations while preserving function
  values through contextual typing.
- Invoke functions whose parameters all have defaults without an empty
  argument list and carry their normalized defaults through lowering.
- Preserve concrete imported generic record fields through IR lowering so C
  and Zig emit the same public layouts across module boundaries.
- Parse identifier-led remainder expressions as positional call arguments
  without requiring redundant parentheses.

### Standard Library

- Remove twelve advertised placeholder modules that had no working contract;
  their overlapping responsibilities remain with `file`, `process`, `thread`,
  `table`, and `crypto`.
- Add shell-free `process.execute`, filesystem inspection/copying/current
  directory operations, byte-oriented text predicates, persistent sequence
  transforms, and ordered map key/value extraction.
- Add typed whole-file `readbytes`, `writebytes`, and `releasebytes`
  operations for arbitrary binary data.
- Add stable-storage `sync`, atomic same-filesystem `replace`, and physical
  file `remove` operations, with durable publication semantics on Windows and
  POSIX hosts.

### Documentation And Testing

- Check every shipped standard module independently before native tests and
  exercise the expanded APIs on both C and Zig backends.
- Document binary ownership, process-buffer flushing, durable publication,
  imported generic fields, and named-argument expression boundaries in the
  guide, specification, catalog, LSP regression, and generated `llm.txt`.

## 0.5.0 - 2026-09-28

### Language And Compiler

- Remove deprecated spellings and compatibility forms from the lexer, parser,
  formatter, IR, type checker, generated bindings, and both native backends so
  every supported construct has one canonical spelling.
- Make direct calls and high-level I/O forms compose consistently with module
  calls, defaults, generics, records, choices, failures, and control flow.
- Reserve compiler-owned operations and type constraints for compiler and
  standard-library internals, with diagnostics that direct applications to the
  public language surface.
- Align module resolution, test discovery and counting, entry-point handling,
  public visibility, and LSP analysis with the compiler's package model.

### Runtime And Optimization

- Replace linear persistent-sequence growth with a shared geometric buffer and
  mutable newest-version tail while preserving logical lengths and copy-on-
  branch behavior for older versions.
- Retain allocation, growth, copy, peak-memory, slow-path, lookup, iteration,
  append, and old-version branch measurements behind build configuration.
- Remove redundant copies, allocations, metadata work, checks, and call
  boundaries exposed by the new representation on both C and Zig backends.

### Documentation And Tooling

- Reconcile the book, language specification, standard-library catalog,
  examples, and generated `llm.txt` with accepted compiler behavior.
- Document module and project discovery, testing, special compiler-owned
  symbols, canonical I/O, absence, failures, generics, constraints, identity,
  cleanup, matching, operator precedence, and backend guarantees in place.
- Compile-check every FOO documentation block, validate expected-error examples,
  and check JSON and shell snippets so stale examples fail the test suite.
- Update the VS Code grammar, snippets, fixtures, and language-server coverage
  to remove deprecated forms and follow the canonical language surface.
- Add cross-feature composition tests covering source resolution, public APIs,
  generics, records, choices, failures, and native C and Zig generation.

## 0.4.1 - 2026-09-28

### Compiler And Runtime

- Keep built-in Zig output on its native fast path so a basic `display`
  program no longer requires generated C service headers or libc.
- Avoid passing Clang's `-target` option to a host GCC build, while preserving
  explicit cross-target handling.
- Exclude top-level `test/` and `benchmark/` trees from flat source discovery
  so they are only compiled by their dedicated commands.

### Testing And Editor

- Give `foo test` the same staged operation interface as builds and runs,
  including checking, compilation, completion, failure details, and timing.
- Compile a selected test body directly as its entry point, removing the
  unnecessary synthetic call boundary.
- Run live LSP analysis through the compiler's complete expansion, entry,
  linking, lint, type, and capability pipeline using project configuration.
- Emit structured editor diagnostics with stable FOO codes, exact ranges,
  suggestions, and fixes, and report successful language-server startup.
- Add live regression coverage for top-level `display`, concise declarations,
  defaults, postfix `try`, `fallback`, and current loop control words.

### Documentation

- Audit the book against compiler behavior, replace speculative examples with
  compiling forms, and explain technical terms in place where they first
  matter.
- Clarify canonical calls, numeric widths, ownership boundaries, native ABI
  declarations, test behavior, supported control flow, and standard-library
  contracts throughout the book and generated LLM reference.
- Keep the registry documentation page synchronized with the revised book and
  improve long-document scrolling and navigation behavior.

## 0.4.0 - 2026-09-28

### Language

- Add default and punctuation-free named arguments, final variadic parameters,
  type-directed overload sets, and sentence-style function declarations and
  calls while retaining parenthesized compatibility forms.
- Add scoped captured closures that share lexical dynamic storage and reject
  unsafe escape, plus declaration-level Boolean function guards.
- Accept `are` for plural bindings and add checked `increase ... by ...` and
  `decrease ... by ...` mutation statements.
- Adopt one-word filenames and language-facing names, enforce the convention
  for standard modules, functions, and types, and rename `hashmap` to `table`.
- Rename the recoverable-result type to `failable T` throughout the language,
  compiler, standard library, examples, editor support, and benchmarks.
- Add `null` as the absence literal for `optional T` while keeping `nothing`
  exclusively as the unit value and raw pointers non-null.
- Add labeled record construction, checked structural record destructuring,
  and unaliased `public use` re-exports with collision diagnostics.
- Preserve `otherwise` and chained `otherwise when` conditionals, with direct
  parser regression coverage.
- Make choice constructors and match patterns compose across aliased imports,
  specialize generic payload and payload-free variants, and retain source-file
  ownership for diagnostics emitted from imported modules.

### Standard Library

- Add explicit `Codec[T]` and immutable `Machine[S, E]` abstractions for typed
  conversion and application-defined state transitions.
- Add typed monotonic `Instant` and `Duration` values, unit constructors,
  elapsed-time calculation, and typed waiting while retaining raw nanosecond
  compatibility operations.
- Add application contracts, bounded deterministic property checks, and an
  explicit pointer-identity operation with checked borrowing on both backends.
- Add explicit iterator cursors, one-process transaction participants,
  deterministic typed generators, checked Gregorian calendar values, fixed
  UTC offsets, and dimension-tagged quantities.

### Optimization

- Replace quadratic persistent sequence append with a shared geometric buffer
  and mutable tail, copy only when a buffer grows or code branches from an older
  version, and add build-gated allocation, copy, peak-memory, and branch metrics.
- Add a shared evidence-gated specialization engine with backend, target, CPU,
  mode, size, overlap, contract, and fallback constraints.
- Eliminate block-local non-escaping stack slots and redundant same-type
  conversions; fuse adjacent private pure calls by removing both call
  boundaries within the target-weighted inlining budget.
- Specialize proven synchronous task continuations into direct calls and fold
  constant JSON quoting into validated compile-time values.
- Add typed generated JSON codecs for scalar and record values on C and Zig,
  including direct final-buffer ownership plus syntax, duplicate-field, kind,
  field, and numeric-range checks.
- Add versioned profile consumption through `build.profile`, use measured hot
  functions to guide inlining, and include profile contents in build identity.
- Dispatch hosted C task pools through IOCP on Windows and epoll/eventfd on
  Linux while retaining honest threaded fallbacks elsewhere.
- Use exact-size direct ownership for seekable file reads and select single-byte,
  small linear, or large skip-table text search by workload.
- Add target-weighted release inlining for small private pure functions and
  canonical sharing of equivalent private pure functions while preserving
  public and address-taken identity.
- Include the compiler executable, optimization mode, and semantic mode in
  artifact cache identities, with explicit cache-key regression coverage.
- Establish internal optimization substitution as a language-wide engineering
  contract: eliminate work first, preserve semantics, retain portable and OS
  fallbacks, and require parity tests plus workload-specific benchmark evidence.
- Formalize execution specialization, boundary elimination, and operation
  fusion as compiler-wide principles, with a mandatory optimization and
  internal implementation review for foundational work.
- Report each selected runtime substrate and its reason through `foo build
  --explain` and `foo run --explain`, including byte transfer, sequence, table,
  task, atomic, and explicit native paths.
- Document current byte-transfer thresholds, generic specialization,
  single-allocation collection transforms, open-addressed tables, reported task
  strategies, cache identity, and the boundaries of planned adaptive work.
- Exercise portable, x86, and AVX2 byte-transfer paths against `memmove` across
  boundary sizes, alignments, and overlapping regions, with benchmark baselines
  kept separate from claims about planned fixed-size expansion.
- Replace the misleading whole-process benchmark comparison with startup and
  runtime baselines, handwritten C/Zig controls, separate build timing, raw
  samples, runtime allocation/copy counters, and compiler optimization facts.
- Expose exact-size sequence construction, remove Zig's second allocation and
  copy when adopting sequence buffers, and retain a dedicated persistent-append
  regression showing its required flat-representation cost.
- Add the portable `#[noinline]` function attribute so call and successful
  failure-propagation workloads measure real call boundaries on C and Zig.

### Website

- Expand the homepage into a responsive language and toolchain overview with
  current syntax, build stages, standard-library layers, project workflows,
  and direct documentation, registry, source, and download paths.
- Add a crawler sitemap and robots policy covering every public documentation
  chapter, plus canonical, Open Graph, Twitter, and structured software
  metadata with route-aware titles and descriptions.
- Generate `/llm.txt` from the complete book, normative specifications, and
  changelog during every website build, then advertise it through page metadata
  and the sitemap.

### Diagnostics

- Group equivalent terminal diagnostics into one source report followed by the
  sorted affected line numbers, including per-file locations when necessary.
- Preserve one record per source span for JSON and LSP consumers, and keep
  diagnostics with related spans separate so important relationships remain
  visible.
- Apply the shared FOO palette to short, verbose, and top-level CLI errors while
  honoring `NO_COLOR`, `TERM=dumb`, and color-free JSON output.
- Preserve each token's source file through parsing and linking so semantic
  diagnostics from an imported module render that module's path and source.

### Editor

- Update foo.iv highlighting, snippets, and live LSP regression coverage for
  sentence declarations, defaults, plural bindings, postfix failure handling,
  intentional mutation, and explicit native C and Zig containers.

### Documentation

- Add dedicated diagnostics, testing, and feature-status chapters to the book
  and registry documentation website.
- Split the beginner path into focused basics, variables, types, operators,
  control-flow, functions, collections, errors, modules, and project lessons,
  each with examples, exercises, and common mistakes.
- Add a categorized standard-library index covering everyday, collection,
  network, data, security, memory, concurrency, platform, and testing modules.
- Rename multiword book and editor files to the one-word `flow`, `expressions`,
  `catalog`, `status`, `language`, and `code` names while retaining old doc URL
  aliases.
- Document declaration scope, mutation, function limitations, collection
  ownership, modules, missing-package behavior, memory placement, borrowing,
  native fixtures, and current tooling boundaries without implying unsupported
  syntax.
- Add a compile-ready patterns chapter covering constructors, codecs, state
  machines, cursors, injected capabilities, explicit transactions, typed time,
  contracts, pointer identity, and facade modules.
- Add a foundations chapter covering inference, absence, comparison, generics,
  modules, data models, memory, ABI, effects, concurrency, time, testing,
  metaprogramming, transactions, and the exact boundary of design-stage ideas.
- Isolate generated documentation-audit snippets by process so concurrent test
  runs cannot overwrite one another or create false compiler failures.

### Projects And Benchmarks

- Generate `src/`, `test/`, and `benchmark/` starters for new applications and
  packages, and clean benchmark artifacts with the other generated outputs.
- Write the default `src/main.iv` entry explicitly in new project manifests and
  add named `entries` so `foo run NAME` selects another executable without
  requiring its path at the command line.
- Add `foo benchmark` with recursive benchmark discovery, selectable C or Zig
  backends, configurable warmups and iterations, raw JSON samples, and
  min/median/mean summaries that exclude compilation time.
- Let `foo test test/file.iv` and `foo benchmark benchmark/file.iv` limit a run
  to one exact file, avoiding unrelated long-running suites.
- Separate generated test artifacts by backend and compiler process so any
  tests for the same suite can run concurrently without locking or overwriting
  each other.
- Isolate native-suite binaries, Nim caches, repository artifacts, and temporary
  directories by invocation so complete native test runs can overlap safely.

### Editor Support

- Stream `foo lsp` requests as they arrive so diagnostics can update while a
  document is edited instead of waiting for the editor process to disconnect.
- Connect the VS Code extension to `foo lsp` for live diagnostics, hover, and
  go-to-definition; add restart and project-watch commands plus a configurable
  compiler path.

### Distribution

- Cross-build Linux ARM64 from x64 Linux or WSL with the pinned managed Zig
  toolchain, and regenerate portable archives, npm packaging, and checksums with
  the installer command instead of retaining stale release files.
- Add an ignored signing environment file with a tracked template and a
  `binaries:signed` command that passes only the GPG fingerprint into WSL.
- Add a release-key generator that creates or reuses a protected Ed25519 GPG
  key, configures the signing fingerprint, exports the release public key, and
  writes a recoverable private/public pair outside the repository from an
  ignored environment-based signing configuration.
- Add a host-aware binary release command that builds Linux directly on Linux,
  builds Windows locally on Windows, and adds a Linux build through WSL when it
  is available while printing the WSL installation command when it is absent.
- Embed the application icon in Windows PE binaries and install Linux desktop,
  icon-theme, and AppStream metadata with packaged ELF binaries.
- Add detached armored GPG signing and verification for Linux ELF binaries,
  selecting the production key only through `FOOSIGNER`.

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
  an explicit `start` function.
- Infer completion for functions that give `nothing`, removing routine
  `give nothing` boilerplate.
- Add concise parameter and result annotations while preserving explicit
  `of type` syntax where useful.
- Introduce the preferred vocabulary `define ... as`, `dynamic`, `stop`,
  `skip`, `fallback`, `multiply`, `subtract`, and `divide`.
- Move `try` after the operation it propagates, so `read try` replaces the
  older `try read` spelling in canonical source and formatted output.
- Add direct `greater than or equal to` and `less than or equal to`
  comparisons so positive conditions do not require `not` wrappers.
- Keep `failable` for functions that may fail.
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
