# Grammar regression corpus

`cases/*.rt` contains real programs and excerpts from Tratio's specification,
compiler fixtures, and standard library. Each file has a corresponding `.json`
assertion file that pins every line and every token's start, end, and full scope
stack. `cases/sources.json` records origin paths and SHA-256 hashes. Collection
normalizes line endings and removes trailing horizontal whitespace; it does
not rewrite language syntax. The compiler fixture is the entire real program,
210 lines, not a repeated or padded example.

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
| compiler | Complete self-hosted compiler lexer, parser, and diagnostics |

The focused assertions under `tests/fixtures` supplement these snapshots with
every reserved word (including words the parser does not yet implement), escape
variants, malformed literals, documentation comments, attributes, and native
blocks. They are retained because a real example corpus alone cannot exercise
every invalid input or reserved word.

Run `npm test` from the extension folder. A missing assertion, changed token
scope, altered fixture hash, or missing keyword fixture fails. The test runner
never updates assertions automatically. `node tests/probe.mjs` deliberately
corrupts an assertion in a temporary corpus and requires the checker to exit 1.

For an intentional change, inspect the highlighted source and focused tests,
then run `npm run snapshots` and review the assertion diff. To refresh source
examples first, run `node tests/collect.mjs` from the compiler checkout.
Neither command should run in CI. Snapshot regeneration is explicitly rejected
when `CI` is set.
