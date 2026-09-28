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
selection forms is an error. `--backend c` and `--backend zig` select the
normal compiler backend. `--mode dev` and `--mode release` override the
project's build mode for that benchmark run. The mode participates in artifact
cache identity, so output compiled under one strategy is not reused for the
other.

Benchmarking introduces no source declaration or altered optimization rules.
For in-process measurement, a benchmark may call the standard `time.measure`
operation. Performance results are observations, not semantic guarantees.
Repository reports use `foo.benchmark/v3`. Each workload records FOO-to-C,
FOO-to-Zig, handwritten C, and handwritten Zig results. Every result identifies
its implementation and backend and keeps build duration, cache reuse, raw
runtime samples, allocation telemetry, and compiler optimization facts separate.
Native compilation is shared by workloads and is marked as such.

The `startup` workload is the process/harness baseline. The `runtime` workload
adds standard runtime initialization and one hosted query. Subtracted medians
are estimates only; raw distributions remain normative benchmark evidence.
Repository reports sample startup at least 21 times after at least five warmups
once the artifact build has completed. `baselineWarmup` and
`baselineIterations` record those counts independently of ordinary workloads.

Allocation telemetry counts payload allocations owned by the measured sequence
path. It does not pretend that allocator metadata, toolchain internals, or OS
bookkeeping are payload bytes. Counters saturate rather than wrap.
