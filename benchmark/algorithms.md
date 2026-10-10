# Algorithm Benchmarks

These are narrow workload measurements, not general language or library rankings.
The packed bitmap algebra fixture and its exact paired results are documented
in [`docs/audit.md`](../docs/audit.md). It covers union, intersection, and
difference over 30,000 packed words and includes a C++20 control.
The machine was an Intel Core i5-1145G7 (8 logical processors) running Windows.
FOO used the C backend in release mode. The C++20 control used Clang 18.1.3,
`-O3 -march=native`, and the installed MSVC standard library. Both programs
constructed the same deterministic input before starting a monotonic timer.
The sorting timer includes the independent output copy and sorting work;
validation and timer output occur afterward. The bitmap timer covers five
counts of 500,000 packed 64-bit words, with one word changed after each count.
Each paired run warmed both executables twice, then alternated nine samples.

| Workload | FOO operation median | C++ operation median | Observation |
| --- | ---: | ---: | --- |
| Original bitmap bit loop | 589.3 ms | `std::popcount`: 1.84 ms | Baseline before optimization. |
| Batched bitmap count with POPCNT dispatch | 2.92 ms; repeat 4.36 ms | `std::popcount`: 1.20 ms; repeat 2.50 ms | Much faster than the old FOO loop, still slower than C++ in both paired runs. |
| Adaptive unsigned radix, 200,000 values below 1,000,003 | 8.72 ms | `std::sort`: 34.40 ms | FOO was 3.9 times faster on this input. |
| Same radix workload, stable comparison | 9.22 ms; repeat 8.58 ms | `std::stable_sort`: 12.94 ms; repeat 9.34 ms | Comparable; the margin varied across runs. |

Before the adaptive radix change, the whole-process FOO benchmark median was
104.8 ms; afterward it was 71.8 ms. Those process samples include startup and
were taken in separate runs, so they are weaker evidence than the paired
operation timings. The radix optimization skips byte passes above the highest
set byte. Uniformly distributed 64-bit values still require eight passes.

The host had substantial competing CPU activity during these measurements.
FOO uses checked sequence access, while the C++ controls use standard-library
iterators. FOO's radix sort is stable and returns an independent sequence;
the C++ controls copy their input before sorting. The bitmap control uses
`std::popcount` over the same packed words. These comparisons support the
specific workloads above; they do not show that FOO algorithms are generally
faster than optimized C++ libraries.

To repeat on Windows, build the native compiler, then run the fixtures one at a
time. Each benchmark build writes `.artifacts/build/app.exe`; compare it before
building the next fixture.

```powershell
npm run native:build
clang++ -O3 -std=c++20 -march=native -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH benchmark/control.cpp -o .artifacts/control.exe
clang -std=c11 -O3 test/native/arch.c -o .artifacts/arch.exe
.artifacts/arch.exe
node bin/foo.mjs benchmark benchmark/prior.iv --backend c --mode release --warmup 1 --iterations 5
node benchmark/compare.mjs .artifacts/build/app.exe .artifacts/control.exe b
node bin/foo.mjs benchmark benchmark/population.iv --backend c --mode release --warmup 1 --iterations 5
node benchmark/compare.mjs .artifacts/build/app.exe .artifacts/control.exe b
node bin/foo.mjs benchmark benchmark/radix.iv --backend c --mode release --warmup 1 --iterations 5
node benchmark/compare.mjs .artifacts/build/app.exe .artifacts/control.exe r
node benchmark/compare.mjs .artifacts/build/app.exe .artifacts/control.exe s
```

`benchmark/prior.iv` preserves the original per-bit loop for a
like-for-like before/after comparison. The fixture programs validate their
results and write the operation duration as a big-endian 64-bit nanosecond
value under `.artifacts/`. `compare.mjs` also reports whole-process times.
