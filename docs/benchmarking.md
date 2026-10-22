# Benchmarking

`foo benchmark` builds and repeatedly runs benchmark programs on the host
target. Set warmups, measured iterations, and build mode explicitly when
recording a result:

```sh
foo benchmark benchmark/features/text.iv --backend qbe --mode release --warmup 3 --iterations 31
```

Compilation and execution are separate measurements. Each program should check
its result before exiting. Record the source, compiler and target, toolchain,
machine, sample count, and spread alongside any reported time. A process time
includes startup and shutdown; it is not the duration of one operation.

The [performance page](performance.md) gives measured FOO times and explains
their scope. The [feature definitions](../benchmark/features/README.md) provide
the workload inputs; [benchmark policy](../benchmark/POLICY.md) covers how
measurements are recorded. See [QBE Backend Support](qbe.md) for target limits.
