# Compiler tests

Run `npm test` or `npm run test:native` from the repository root. Every `.nim`
file under `test` is compiled and executed independently, and the complete result
set is written to `.artifacts/native-tests/results.json`.

Fixtures and reviewed expectations live beside their suites. The backend and
build suites compile real C and Zig programs, while `runner_execute.nim` exercises
the public test pipeline. `foo test std --backend c` and
`foo test std --backend zig` run the six packaged standard-library programs.

Editor grammar tests remain available through `npm run test:editor`. The separate
`npm run test:host` command opens an isolated VS Code Development Host.
