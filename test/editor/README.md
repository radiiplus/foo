# Grammar regression corpus

`cases/*.iv` contains real programs and excerpts from FOO's specification,
compiler fixtures, and standard library. Each file has a corresponding `.json`
assertion file that pins every line and every token's start, end, and full scope
stack. `cases/sources.json` records origin paths and SHA-256 hashes. Collection
normalizes line endings and removes trailing horizontal whitespace; it does
not rewrite language syntax. The library fixture combines four complete source
units with origin comments, providing over 200 lines of real code. It is a lexical
corpus, not a single executable program.

| Family | Origin |
| --- | --- |
| declarations | The frozen naming document's generic declaration example |
| types | Advanced-types specification: choices, vectors, records, unions, callbacks |
| interop | C interop specification's header import example |
| concurrency | Concurrency specification's complete scoped-task example |
| control | Existing compiler lexer fixture with branches, loops, match, and cleanup |
| pointers | Real deque module with pointer parameters and fields |
| errors | Real crypto module's fallible API declarations |
| platforms | Real Windows module declarations |
| library | Sequence and text modules, plus collections and services tests |

The focused assertions under `fixtures` supplement these snapshots with
every reserved word (including words the parser does not yet implement), escape
variants, malformed literals, documentation comments, attributes, and native
blocks. They are retained because a real example corpus alone cannot exercise
every invalid input or reserved word.

Run `npm test` from the extension folder. A missing assertion, changed token
scope, altered fixture hash, or missing keyword fixture fails. The test runner
never updates assertions automatically. `node test/editor/probe.mjs` from the repository root deliberately
corrupts an assertion in a temporary corpus and requires the checker to exit 1.

For an intentional change, inspect the highlighted source and focused tests,
then run `npm run snapshots` and review the assertion diff. To refresh source
examples first, run `node test/editor/collect.mjs` from the compiler checkout.
To refresh one family, append its name, for example `node test/editor/collect.mjs library`.
Neither command should run in CI. Snapshot regeneration is explicitly rejected
when `CI` is set.
