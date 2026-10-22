# Contributing to FOO

Documentation changes follow the [documentation policy](docs/POLICY.md).
Read the relevant index and preserve unique contracts and evidence when
consolidating pages. Check links, examples, and implementation claims before
reporting a documentation change as complete.

FOO changes often cross the language grammar, QBE backend, runtime, tooling,
documentation, and editor support. Keep a contribution focused, state its
observable behavior, and test the paths it changes.

## Before opening a change

- Search existing issues and the current [changelog](CHANGELOG.md).
- Use a private security advisory for vulnerabilities; see
  [SECURITY.md](SECURITY.md).
- Open a feature issue before making a large grammar, type-system, ABI, package,
  or standard-library contract change.
- Do not claim a performance improvement without a reproducible baseline and
  before/after measurements.

## Development setup

The repository expects Node.js 22.13 or newer and Nim 2.2. Native builds use
the managed QBE toolchain and target-specific assembler and linker tools.
Windows release resources also require the Windows SDK resource compiler.

```sh
npm install
npm run native:build
node bin/foo.mjs doctor
```

Build artifacts belong under `.artifacts/`; completed FOO project products use
`output/`. Do not commit generated caches, local signing environments, private
keys, or release credentials.

## Repository conventions

- Follow [naming and shared-code rules](docs/naming.md). Keep required ABI,
  toolchain, and external file spellings compatible.
- Follow the surrounding Nim, JavaScript, FOO, C, and Markdown style.
- Check QBE behavior in each affected target and mode; use the
  [target gates](test/backend/qbe/TARGETS.md) for target-specific changes.
- Add focused regression coverage beside the affected subsystem.
- Update the specification for contracts and the guide for user-facing usage.
- Add an entry under `Unreleased` in [CHANGELOG.md](CHANGELOG.md).
- Regenerate `registry/ui/public/llm.txt` with
  `node registry/ui/scripts/llm.mjs` after documentation changes.

If the compiler, standard library declarations, guide, or specification disagree,
do not silently choose one as correct. Document the observed behavior and use
the implementation-inconsistency issue form when the right contract is unclear.

## Tests

Follow [test maintenance](test/POLICY.md) when adding, merging, or retiring
tests. Run the smallest relevant region while developing. Examples:

```sh
npm run check
npm run test:docs
npm run test:editor
npm run test:core
node test/run.mjs runtime --list
```

The native runner discovers Nim leaves under `test/`, batches compatible
modules, limits parallel work, and writes reports under `.artifacts/test/`.
Select one leaf with `node test/run.mjs REGION --only test/path/to/leaf`.

Run each affected domain command when the change affects shared compiler
behavior. Backend, cross-target, installer, and benchmark changes may require
their focused platform commands as well. State
which checks were run and which could not be run in the pull request.

## Performance changes

Establish startup and harness cost before attributing time to FOO code. Compare
the current compiler with an exact baseline and matched controls, including a
pinned Rust control when making a Rust comparison. Follow the
[benchmark policy](benchmark/POLICY.md): record raw paired samples, variability,
allocation/copy metrics where relevant, target, CPU, toolchain, and build mode.

## Pull requests

Keep commits reviewable and avoid unrelated formatting or generated-file churn.
Explain the problem, the behavior after the change, compatibility impact, and
verification. Screenshots are useful for editor or website changes; terminal
transcripts are useful for compiler and toolchain behavior. A pull request must
not contain private signing material or unpublished vulnerability details.
