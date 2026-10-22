# Benchmarking

Version: 2.

`foo benchmark` discovers `.iv` files recursively under the project
`benchmark/` directory. The normalized relative path without `.iv` is the
benchmark name. Discovery excludes symbolic links, `.artifacts`, `.git`, and
`node_modules`, and orders names lexically.

Each benchmark is an ordinary executable entry. It is built once, then executed
for the configured nonnegative warmup count and positive timed iteration count.
The default is one warmup and ten timed iterations. Build time is excluded;
process startup and shutdown are included. A nonzero process status fails the
benchmark and no later samples are collected for it.

Benchmark executables target the current host regardless of the ordering of
the project's configured release targets. Cross-compiled executables are not
run as benchmarks.

Results expose every elapsed millisecond sample and calculate minimum, median,
arithmetic mean, maximum, and the nearest-rank 95th percentile. For an even
sample count, median is the mean of the two middle sorted samples. Median is
the primary comparison; mean, maximum, and the 95th percentile show how slow
runs affect the distribution. Human output uses the shared operation
interface. JSON events contain the name, build mode, warmup and iteration
counts, samples, and summary values.

`foo benchmark NAME` selects names containing NAME. `--filter NAME` has the
same matching behavior. An argument ending in `.iv` selects that exact file
and must resolve inside the project's `benchmark/` directory. Supplying both
selection forms is an error. `--backend qbe` selects the
compiler backend explicitly. `--mode dev` and `--mode release` override the
project's build mode for that benchmark run. The mode participates in artifact
cache identity, so output compiled under one strategy is not reused for the
other.

Benchmarking introduces no source declaration or altered optimization rules.
For in-process measurement, a benchmark may call the standard `time.measure`
operation. Performance results are observations, not semantic guarantees.
Repository reports use `foo.benchmark/v4`. Each workload records FOO through
QBE and native C, C++, Rust, and Zig controls by default. The C and C++
controls compile the same source as different languages. Every
result identifies its implementation and backend and keeps build duration, cache
reuse, raw runtime samples, allocation telemetry, and compiler optimization facts
separate. Native compilation is shared by workloads and is marked as such.
FOO results record raw median ratios against each control and retain the older
Rust-specific fields for report consumers. Ratios do not establish a
language-wide performance ordering.
Comparisons also record per-round wins, round count, and the median paired
FOO-minus-control duration; these make noisy or overlapping runs visible.
The `arithmetic` and `global` workloads perform the same checked sum with
local and module-global mutable state respectively. Each control uses the
corresponding storage pattern. This pair exposes optimizer sensitivity to
source organization instead of hiding it in an unmatched control.

The report runner writes isolated `.artifacts/bench` reports and saves executable
headers and disassembly by default. `--output` explicitly publishes a report
elsewhere. Binary inspection is evidence about emitted code, not a substitute
for correctness or failure-path tests. `benchmark/POLICY.md` governs catalog
ownership, comparison and optimization claims.
Repository reports compile and validate executables before timing them in
rotating FOO/control order for each workload. Startup gets at least 21 rounds;
other workloads use the requested iteration count.

The `startup` workload is the process/harness baseline. The `runtime` workload
adds standard runtime initialization and one hosted query. Subtracted medians
are estimates only; raw distributions remain normative benchmark evidence.
Repository reports sample startup at least 21 times after at least five warmups
once the artifact build has completed. `baselineWarmup` and
`baselineIterations` record those counts independently of ordinary workloads.

Allocation telemetry counts payload allocations owned by the measured sequence
path. It does not pretend that allocator metadata, toolchain internals, or OS
bookkeeping are payload bytes. Counters saturate rather than wrap.
