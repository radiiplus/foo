# Benchmarking

A test answers, "Is this code correct?" A benchmark (a controlled performance
measurement) answers, "How long does
this program take?" Keep those jobs separate: tests belong in `test/`, and
benchmarks belong in `benchmark/`.

## Your first benchmark

Every project created by `foo new` includes `benchmark/main.iv`. Replace its
starter loop with the work you want to measure. A benchmark is an ordinary FOO
program, so top-level statements work and `start` remains optional.

```foo
dynamic counter is 0.
while counter less than 10000 {
  set counter to counter plus 1.
}
```

From the project directory, run:

```sh
foo benchmark
```

FOO builds the benchmark once, runs one untimed warmup (a practice run that
lets the system settle), then measures it ten times. Compilation time is not
included in the samples. Benchmarks always build for the current computer,
even when `project.json` lists other release targets first, because a
cross-compiled program cannot be measured on the machine running the command.

## Reading the result

```text
Results
└─ main  median 1.42 ms · p95 1.61 ms · mean 1.47 ms · min 1.35 ms · max 1.64 ms  ✓
```

- `median` is the middle run and is usually the best number to compare.
- `mean` is the average of every timed run and is more sensitive to slow runs.
- `p95` is the nearest-rank 95th percentile (95 percent of samples are at or
  below this value) and exposes the slower tail.
- `min` is the fastest observed run, not a promise that every run is that fast.
- `max` is the slowest observed run and is especially sensitive to interference.

FOO measures the whole benchmark process, including program startup and
shutdown. This makes the command useful for application and workflow
benchmarks. Use `time.measure` inside one long-running benchmark when you need
to isolate a very small operation.

## Repository benchmark suite

The FOO repository keeps separate workloads for different compiler and runtime
boundaries:

| Workload | What it measures |
| --- | --- |
| `allocation` | Pre-sized construction and an exact-size generic transformation. |
| `arithmetic` | Checked loop control, addition, assignment, and increment. |
| `branch` | Repeated append from a retained sequence version. |
| `calls` | Private calls and release-mode inlining. |
| `failure` | Successful typed results and postfix `try` propagation. |
| `generic` | Concrete generic specialization inside a checked loop. |
| `growth` | Persistent shared-tail append and one verified old-version branch. |
| `iteration` | Ordered traversal of one million sequence values. |
| `known` | Validation when a value is already known during the build. |
| `lookup` | One million checked dynamic sequence lookups. |
| `runtime` | Standard runtime initialization and one hosted query. |
| `startup` | Process and generated-program harness floor (the fixed cost of starting and measuring) without library work. |

Run the suite using the project's configured mode and one backend with:

```sh
npm run benchmark
```

To measure C and Zig in both `dev` and `release`, then refresh the report used
by the website:

```sh
npm run benchmark:report
```

The version 3 report keeps every raw sample in `benchmark/results.json` and
records four implementations for each workload (the specific operation being
measured): FOO through C, FOO through
Zig, handwritten C, and handwritten Zig. Compilation duration and cache reuse
are separate from runtime samples. Runtime samples include process startup and
shutdown, so the report records both `startup` and `runtime` baselines.

The startup artifact receives at least five warmups and 21 timed samples after
its build has completed. This separate pass reduces post-link scanning and
one-off scheduler effects (timing changes caused by the operating system
choosing when work runs) without pretending that repeating a tiny workload
makes the operation itself larger. The report records the baseline counts
separately from the ordinary workload counts.

Startup-adjusted and runtime-adjusted medians are estimates produced by
subtracting baseline medians. They can expose fixed-cost domination, but they
are not direct in-process timings and may become zero when scheduler noise makes
the workload sample faster than its baseline. Always inspect raw samples.

Allocation-aware runtimes additionally report payload allocations (successful
requests for data memory), allocated
bytes, reallocations, copied bytes, growth operations, growth copies, average
capacity, maximum capacity, effective growth factor, current and peak live
bytes, bytes retained by older sequence versions, slow-path hits, and branch
operations and copies. Compiler telemetry (measurements reported by the
compiler) reports generic specializations (versions made for exact types),
inlined calls (calls replaced with their function bodies), eliminated bounds checks,
eliminated allocations and boundaries, and fused pipelines. A zero is an
observed compiler fact, not an implied optimization.

The current investigation and measurements are in [Performance Report](performance.md).

These measurements compare specific generated programs and handwritten
controls under recorded conditions. They do not establish that FOO is broadly
"as fast as C or Zig."

The report tool verifies that every cataloged workload produced one event for
each requested backend and mode. A missing or unexpected workload fails report
generation, preventing a report from silently omitting inconvenient results.

Compiler time and memory are separate concerns. The runtime samples exclude
both, so use build telemetry to detect slow or memory-heavy compilation rather
than mixing compiler cost into generated-program results.

## More than one benchmark

Add one `.iv` file per scenario:

```text
benchmark/
├─ parser.iv
├─ request.iv
└─ storage/
   └─ lookup.iv
```

Run all of them with `foo benchmark`, select by name, or pass the exact file:

```sh
foo benchmark parser
foo benchmark storage/lookup
foo benchmark benchmark/parser.iv
foo benchmark --filter request
```

Names are relative to `benchmark/` and use `/` on every operating system. An
`.iv` argument is treated as an exact file rather than a name filter, so it is
the clearest choice when a project has many long-running benchmarks.

## Choosing the sample count

```sh
foo benchmark --warmup 3 --iterations 25
foo benchmark parser --backend c --iterations 20
foo benchmark parser --backend c --mode release --iterations 20
```

Warmups must be zero or greater. Timed iterations (repeated measured runs) must
be at least one. More iterations reduce random noise but take longer. Use the same backend, build
mode, machine load, and sample count when comparing two results.

Use `--json` when another tool needs the raw samples and summary values,
including maximum and the 95th percentile:

```sh
foo benchmark --json
```

## Avoiding misleading numbers

- Do not print inside a tight benchmark unless output is what you are measuring.
- Keep network, disk, and background-system activity consistent between runs.
- Compare results on the same machine and power mode.
- Measure a realistic amount of work so process startup does not dominate.
- Treat a benchmark as evidence, not a language guarantee.

A nonzero benchmark exit status fails that benchmark and stops collecting its
samples. FOO reports the failure beside its benchmark name.
