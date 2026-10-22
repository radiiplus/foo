# Compiler optimization research policy

## Documentation requirements

Before creating, editing, merging, or removing documentation, read
`docs/POLICY.md` and the relevant documentation index. Inspect existing
material, preserve unique technical contracts, verify implementation claims,
validate examples where practical, and update links and indexes. Keep user
guidance in `docs/`, formal contracts in `specs/`, and reproducible performance
evidence in `benchmark/`. Do not treat a specification as proof of current
support. For repository-wide restructuring, produce a file-by-file migration
plan before deleting or merging material; validate each stage and report what
was retained, merged, or removed.

This repository contains active compiler/runtime performance research. Read
`benchmark/POLICY.md` and `benchmark/features/README.md` before changing compiler optimization, generated
runtime or service code, memory ownership, or the feature benchmarks.

- Keep benchmark sources and controls in the active benchmark tree. Store run
  reports, raw samples, and reproducible artifacts under ignored `.artifacts/`.
  Do not publish a performance claim without its comparable run data.
- Preserve the current target-specific optimization policy unless a replacement
  gives a reproducible speed improvement on the same target and representative
  workloads, with correct results and no material regression in other covered
  features. Compare against the current compiler as well as a pinned Rust control
  when claiming a Rust advantage. Never claim universal superiority from one
  workload or machine.
- Benchmark at least the five independent feature families in
  `benchmark/features/`: text, decimal, records, typed JSON, and mutable tables.
  Alternate paired runs after warmups, record sample counts and variability, and
  include build mode, target, toolchain versions, flags, hardware, executable
  hashes, and the exact baseline. Extend the batch for newly affected features.
- Inspect generated QBE IL or WAT, C, objects, and runtime behavior before attributing
  a gain to a compiler pass. Keep allocation, aliasing, lifetimes, zero-iteration
  loops, overflow, error paths, and FFI/ABI behavior intact. A faster result that
  weakens these contracts is not an accepted optimization.
- Qualify changes on every affected target and mode. Run the relevant semantic
  fixtures and target gates for hosted Windows, freestanding, WASI and threads,
  GPU/shaders, and direct syscalls when their code paths are touched. A Windows
  x64 measurement does not justify enabling a policy on another target. Document
  unavailable SDKs or devices and leave those targets unqualified.
- Keep optimization decisions explicit in build metadata and cache identity so
  the compiled artifact can be tied back to its policy. Preserve dev behavior
  unless separately measured and validated.

Target gate instructions are in `test/backend/qbe/TARGETS.md`. This policy
allows a faster, proven replacement; it does not freeze the implementation.
