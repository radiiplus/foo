# Contributing to FOO

FOO changes often cross the language grammar, both native backends, tooling,
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

The repository expects Node.js 22.13 or newer and Nim 2.2. The managed Zig
toolchain is installed by the project. Windows native compiler builds also need
LLVM so `clang` and `llvm-rc` are available.

```sh
npm install
npm run native:build
node bin/foo.mjs doctor
```

Build artifacts belong under `.artifacts/`; completed FOO project products use
`output/`. Do not commit generated caches, local signing environments, private
keys, or release credentials.

## Repository conventions

- Use one-word names for FOO files and declarations, public FOO APIs, and
  repository-owned Markdown filenames. Keep established words such as
  `checksum`; split constructed joins into modules or choose one clear word.
  Foreign ABI symbols, required toolchain filenames, and GitHub metadata are
  exceptions. Nim, C, Zig, JavaScript, and TypeScript internals follow their
  existing conventions.
- Follow the surrounding Nim, JavaScript, FOO, C, Zig, and Markdown style.
- Keep public behavior consistent between the C and Zig backends.
- Add focused regression coverage beside the affected subsystem.
- Update the specification for contracts and the guide for user-facing usage.
- Add an entry under `Unreleased` in [CHANGELOG.md](CHANGELOG.md).
- Regenerate `registry/ui/public/llm.txt` with
  `node registry/ui/scripts/llm.mjs` after documentation changes.

If the compiler, standard library declarations, guide, or two backends disagree,
do not silently choose one as correct. Document the observed behavior and use
the implementation-inconsistency issue form when the right contract is unclear.

## Tests

Run the smallest relevant tests while developing. Examples:

```sh
npm run check
npm run test:docs
npm run test:editor
npm run test:native -- --jobs=2
```

Individual Nim tests can also be compiled and run directly when isolating a
failure. The native runner discovers every `.nim` file under `test/`, limits
parallel work, and writes its report under `.artifacts/native-tests/`.

Use `npm test` for the complete standard-library and native suite when the
change affects shared compiler behavior. Backend, cross-target, installer, and
benchmark changes may require their focused platform commands as well. State
which checks were run and which could not be run in the pull request.

## Performance changes

Establish startup and harness cost before attributing time to FOO code. Compare
equivalent FOO-to-C, FOO-to-Zig, handwritten C, handwritten Zig, and handwritten
Rust workloads where the benchmark report defines them. Record raw samples,
allocation/copy metrics where relevant, the target, CPU, toolchain, and build
mode. Prefer eliminating work, allocations, and copies before instruction-level
optimization.

## Pull requests

Keep commits reviewable and avoid unrelated formatting or generated-file churn.
Explain the problem, the behavior after the change, compatibility impact, and
verification. Screenshots are useful for editor or website changes; terminal
transcripts are useful for compiler and toolchain behavior. A pull request must
not contain private signing material or unpublished vulnerability details.
