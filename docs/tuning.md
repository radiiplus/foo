# Optimization

Dev and release builds preserve the same language behavior. Optimization
decisions are tied to target and mode in QBE artifact metadata and cache
identity. A performance policy is enabled only after representative workloads
show correct results, an improvement against the current compiler and no
material regression in other covered features.

The five independent feature families are in
[`benchmark/features/README.md`](../benchmark/features/README.md). Follow
[`benchmark/POLICY.md`](../benchmark/POLICY.md) when measuring a proposed
change. See [QBE Backend Support](qbe.md) for target limits.
