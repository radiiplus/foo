# Compiler Tests

The [test maintenance policy](POLICY.md) defines ownership, fixture layout
and evidence requirements. Run `node test/native/run.mjs --list` to inspect
native Nim suites, or `node test/native/run.mjs --filter=backend/qbe` for the
QBE backend tests. `node test/matrix.mjs --backend qbe` runs the semantic
fixture matrix.

QBE Nim suites remain under `backend/qbe/`, with C and assembly inputs in
`backend/qbe/c/` and JavaScript target runners in `backend/qbe/scripts/`.
Native C harnesses live in `native/c/`, while FOO inputs and expected output
stay together in `native/fixtures/`.

Regional commands (`npm run test:core`, `test:runtime`, `test:targets`,
`test:net`, `test:packages`, `test:release`, `test:editor`, `test:bench`) select
their named domains. `node test/run.mjs REGION --list` shows selected leaves.
`node test/regional.mjs` checks regional routing. Generated products and logs
stay under `.artifacts/test` or `FOO_ARTIFACT_ROOT`.

Target-specific prerequisites and gates are listed in
[`backend/qbe/TARGETS.md`](backend/qbe/TARGETS.md). WASI and threaded execution
require WABT and a compatible runner; freestanding and firmware tests require
their named QEMU or OVMF environment. Unavailable target gates are reported as
unqualified.

`node test/library/check.mjs --names-only` checks library and active fixture
names. Refresh the inventory with `python test/support/inventory.py`, then
run `node test/support/audit.mjs`, `node test/backend-policy.mjs` and
`node test/regional.mjs` after adding or removing test leaves.
