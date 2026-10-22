# Feature benchmarks

Five independent release workloads cover text search, decimal accumulation,
record construction, typed JSON round trips, and mutable table lookup. Each
FOO file validates its result before exit. The Rust control selects the
matching operation with `FOO_FEATURE_CASE=text|decimal|record|json|table`.
The current inputs are `text.iv`, `decimal.iv`, `record.iv`, `json.iv`, and
`table.iv`.
Run `tools/qbe/hosted/verify.mjs` to check these inputs in dev and release.
For performance comparisons, use the matching Rust control, alternate paired
runs after warmups, and keep raw samples in the run's isolated artifact
directory. See [benchmark policy](../POLICY.md) for the measurement and
correctness requirements.
