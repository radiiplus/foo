# Test maintenance

## Ownership

Keep repository tests, fixtures, test runners, and test-only helpers under
`test/`. `src/test/` implements the user-facing `foo test` command; it is
production source. `tools/` contains general build and release tools, not a
second test tree. Put benchmarks under `benchmark/`.

Route tests through `test/regions.json` using the owning domain in
`specs/layout.md`: compiler behavior in `core`, network behavior in
`net`, other runtime behavior in `runtime`, target behavior in `targets`, build
and package behavior in `packages`, distribution behavior in `release`, editor
behavior in `editor`, and performance evidence in `bench`. A test crossing
domains belongs to the boundary whose behavior it verifies. Declare a region
dependency only when that region's result is required to interpret the test.

## Write the smallest useful check

- State one observable contract per test. Check a value, diagnostic, output
  byte sequence, artifact, or cleanup effect. Avoid assertions that only repeat
  an implementation expression.
- Search the owning domain before adding a case. Extend a table of inputs and
  expected results when setup and contract are the same. Keep a separate case
  only when its failure needs a distinct fixture, process, target, or report.
- Use representative normal and boundary inputs. An exhaustive matrix needs a
  reason, a generator, and a bounded size. Do not copy large generated cases
  into another suite merely to exercise a different runner.
- Keep one primary assertion owner. Add an integration test for behavior that
  crosses a real boundary, not to repeat all unit cases through the CLI.
- Keep fixtures beside their owner. Write temporary sources and binaries under
  `.artifacts/test` or the runner's isolated output directory. Do not check in
  generated binaries, compiler caches, or copied fixture trees.
- Preserve isolation for child-process dispatch, persistent environment changes,
  target-specific tools, and platform gates. Batch compatible Nim leaves through
  `test/suites/`; the planner also batches selected subsets for regional runs.

## Review and cleanup

Before retiring a test, name the contract it covers and identify the retained
case that proves it. Remove an exact duplicate only after comparing inputs,
expected observations, backend, mode, and target. Do not infer duplication from
similar filenames or assertion counts. Update `test/regions.json` and any
direct runner references when paths change. Keep the current test inventory in
`test/inventory.json` aligned with source files when tests move or are removed.

Run `node test/run.mjs REGION --list` to inspect routing and
`node test/native/run.mjs --list` to inspect compile units. After test source
changes, explicitly refresh `test/inventory.json` with
`python test/support/inventory.py`, review the diff, and run
`node test/support/audit.mjs`. Run the affected regional gates separately;
claim full cross-domain acceptance only after each domain passes. Keep the
reported leaf and assertion evidence when merging files or changing batches.
