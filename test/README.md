# Compiler tests

Run `npm test` or `npm run test:native` from the repository root. Every `.nim`
file under `test` is compiled and executed independently, and the complete result
set is written to `.artifacts/native-tests/results.json`. Each invocation keeps
its binaries, compiler caches, temporary files, and a copy of its report under
`.artifacts/native-tests/run-*`, so native suites can overlap safely.

Fixtures and reviewed expectations live beside their suites. The backend and
build suites compile real C and Zig programs, while `execute.nim` exercises
the public test pipeline. `foo test std --backend c` and
`foo test std --backend zig` run the eight packaged standard-library programs.
Generated programs are separated by backend and process under
`.artifacts/test/c` and `.artifacts/test/zig`, so any backend suites may run at
the same time.

Editor grammar tests remain available through `npm run test:editor`. The separate
`npm run test:host` command opens an isolated VS Code Development Host.
