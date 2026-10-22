# Performance

The table records FOO QBE hosted release process times from the October 21,
2026 five-feature run. Each cell shows the median and full range of 31 measured
runs after three warmups, in milliseconds. These are measurements of those
executables on one machine, not a speed guarantee for a later build.

| Feature workload | Windows x64 | Linux x64 under WSL2 |
| --- | ---: | ---: |
| Text search | 57.6 (43.9-88.1) | 26.5 (21.5-37.9) |
| Decimal accumulation | 31.4 (25.7-50.9) | 11.0 (10.5-13.1) |
| Record construction | 23.5 (19.4-33.4) | 10.4 (8.5-22.9) |
| Typed JSON round trips | 60.1 (48.8-148.3) | 443.9 (106.2-641.4) |
| Mutable table lookup | 163.8 (146.4-374.1) | 608.1 (481.4-712.6) |

The host was an Intel Core i5-1145G7. Windows ran build 10.0.26200; Linux ran
kernel 6.18.33.2-microsoft-standard-WSL2. The raw records, including the
executable hashes and alternating run order, are in the local run artifacts at
`.artifacts/bench-opt/qbe-direct-codec-2026-10-21/windows-five-paired.json`
and `linux-five-paired.json`. The wide JSON and table ranges, especially on
WSL2, limit what these process times can establish.

Measure the program and target you intend to ship. Build in the intended mode,
verify the result, and run enough warmups and samples to see the distribution.
For repository workloads, start with [benchmarking](benchmarking.md) and the
[feature inputs](../benchmark/features/README.md).

A process time includes startup, shutdown, runtime setup, and the measured work.
Use an operation timer inside the program when startup would obscure the work
being measured. Keep both measurements when they answer different questions.
Report the median and sample spread; do not infer a general speed ranking from
one workload.

For a compiler or runtime change, compare against the current compiler and a
control that performs equivalent checked work. Alternate paired runs after
warmups on a quiet machine. Record source and executable hashes, tool versions,
flags, target, mode, hardware, commands, raw samples, and variability in the
run's ignored `.artifacts/` directory. The [benchmark policy](../benchmark/POLICY.md)
defines the qualification checks. The [QBE support page](qbe.md) lists current
target limits.
