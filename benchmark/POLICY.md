# Benchmark maintenance

## Ownership and layout

Keep measured FOO programs and controls under `benchmark/`, the report runner
under `tools/benchmark.mjs`, and correctness tests under `test/`. The current
general-purpose suite is the workload list in `benchmark/catalog.json`, with
one `.iv` source per operation in `workloads/`. C and C++ controls are in
`controls/c/`, with Rust and Zig controls in their matching directories.
`native.c` and `native.cpp` share the same implementation so their compiler
comparison does not duplicate workload logic. `algorithms/` contains algorithm
sources used by semantic fixtures.
The five feature inputs use their family names under `features/`. Compilation
fixtures live in `compilation/fixtures/` and QBE profiling scripts in
`compilation/qbe/`.

Put generated executables, caches, reports, and binary dumps in an isolated
`.artifacts/bench` run. Each run must record its machine, command, and source
identity there. Keep one authoritative catalog entry and avoid copying the same
timing case into multiple directories. Retire an obsolete case only after identifying
the retained workload and the behavior it covers.

## Comparable measurements

- Every catalog report runs FOO through QBE and the four controls in both
  build modes by default. A focused subset is diagnostic, not a broad ranking.
- Each control must perform the cataloged work, validate its result, and fail
  on an incorrect outcome. Shared C/C++ code measures the compiler's treatment
  of the same algorithm, not the performance of the C++ standard library.
- Keep mutable hot-loop state local to each entry function in every language.
  A module-global FOO counter and a local native counter are different
  optimization problems. The `global` workload deliberately uses global
  state in all five languages to measure how much each compiler recovers.
- Record fixed inputs, compiler versions, optimization modes, architecture,
  startup baseline, raw samples, and allocation telemetry in the run's isolated
  artifacts. Compare equivalent
  semantics and note costs a control excludes. Do not equate a payload counter
  with whole-process memory.
- Use paired reruns on a quiet machine to investigate a gap. Check whether the
  raw distributions separate before attributing the gap to generated code.
  Inspect the faster control's source and disassembly, then test an isolated
  compiler or runtime hypothesis. Record rejected candidates as well as wins.
- When startup or machine contention dominates samples, lengthen the actual
  checked work and alternate candidate/control order. Preserve per-pair
  samples and report wins and dispersion. A faster minimum or one favorable
  median does not establish lower variance or noisy-host stability. The report
  runner compiles first, then rotates FOO and controls within each workload.
- Require correctness, control-regression, allocation, and repeat-run checks
  when qualifying an algorithm replacement.

## Optimization gate

Investigate QBE lowering or IR when the issue is generated code shared by FOO
programs. Native runtime fragments are compiled separately; verify their
generated objects when a claim covers them. Retain pre-change and candidate IR,
toolchain manifests, executable hashes, headers, and disassembly. The report
runner stores the current executable dumps and FOO IR in its artifact run.

Before promoting an optimization, run the relevant regional semantic tests in
both modes and inspect the generated machine instructions. Check checked
arithmetic, result/error precedence, memory ownership, ordering, and target
ABI where relevant. Binary inspection shows what was emitted; it does not
replace runtime and failure-path tests. Then repeat paired performance runs
and check unrelated controls for regressions.

Direct syscalls and stream writes are observable operations. A compiler may
plan adjacent source operations ahead of time, but must preserve each call's
result, partial write, flush visibility, error point, and ordering across
reads, sync, locks, task handoff, and basic blocks. Current stream writes
flush individually, so `io-batches.json` reports candidates but forms zero
batches. Do not turn on batching until a separately specified API or a proven
equivalence rule has differential success/failure tests, target-specific binary
checks, and a paired speedup. See `docs/runtime.md`.
