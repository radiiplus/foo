# Naming and shared code

Use an ordinary single word for FOO source filenames, types, routines, and
bindings: `Certificate`, `selection`, `prepare`, `inputs`, and `source`. Keep the
subject in its module: `qbe/benchmark/hosted.mjs`, `vendor/audit.mjs`, and
`test/inventory.py`. Do not replace underscores with concatenation or camel case.
Use module qualification when short names would collide; distinct operations
need distinct names even when their arguments have the same types.

Vendor and platform API spellings, exported FOO runtime symbols, environment
variables, command-line flags, serialized report/cache keys, and external file
formats remain compatibility boundaries. Existing public FOO library APIs keep
their names; any future public rename must retain an alias. Standard repository
filenames such as `package-lock.json` and `CODE_OF_CONDUCT.md` retain their
established external names. Generated evidence retains its original identities;
renamed source paths require fresh qualification rather than rewriting evidence.
Exported compiler record fields consumed by integrations also retain compatible
spellings. Imported platform calls keep their provider's names.

Shared tooling lives in `tools/arguments.mjs`, `nim.mjs`, `statistics.mjs`, and
`tree.mjs`. Tree discovery excludes generated caches and does not follow directory
links. Native compiler inputs and the active test plan use this traversal. Shared
Nim cleanup lives in `src/build/files.nim`; package, registry, and CLI callers keep
their original path confinement checks and cleanup rules. It never follows links
when descending a directory.

Run `node test/tools.mjs` to check argument errors, compiler discovery without
execution, deterministic/pruned traversal, statistics, relative imports, and
packaging dependencies. Run `node test/native/speed.mjs --integration` to verify
test grouping, completion accounting, failure injection, resource invalidation,
and changed compile-time inputs. Refresh the reviewable coverage inventory with
`python test/support/inventory.py`, then check it with `node test/support/audit.mjs`.

The QBE build policy is recorded in `.qbe.json` artifact metadata. Backend
qualification commands live under `tools/qbe/`. Compiler latency measurement is
`node tools/latency.mjs --pairs=3`. Release and benchmark snapshots include every
shared helper they import, and ordinary builds continue to work offline.
