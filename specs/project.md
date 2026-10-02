# Projects

Version: 1. Configuration file: `project.json`.

A project declares its language version, capability level and dependencies.
The application version and configuration schema version are separate fields.

```json
{
  "schema": 1,
  "name": "myapp",
  "version": "1.0.0",
  "license": "MIT OR Apache-2.0",
  "language": "1",
  "source": "src",
  "entry": "src/main.iv",
  "entries": { "worker": "src/worker.iv" },
  "requires": "base",
  "dependencies": { "http": "^1.2.0" }
}
```

## Schema

The root is a JSON object. Duplicate keys and unknown properties are errors.
Required properties are name, version, language, requires and dependencies.
An absent schema means 1; canonical serialization writes it explicitly.
Other schema or language versions require a matching specification.

| Property | Type and constraint |
| --- | --- |
| schema | Integer, exactly 1 |
| name | Nonempty ASCII package name; optional namespace separated by one `/`; each component matches `[a-z][a-z0-9-]*` |
| version | Exact stable version `MAJOR.MINOR.PATCH`, nonnegative integers without leading zeros |
| license | Optional SPDX license expression describing the project license |
| language | String, exactly `"1"` |
| requires | Exactly base, system, machine or hardware |
| dependencies | Object from package names to dependency strings |
| devDependencies | Development-only dependency object |
| optionalDependencies | Dependency object whose unavailable entries may be omitted |
| platformDependencies | Object from platform selectors to dependency objects |
| source | Optional project-relative source directory; defaults to src if that directory exists, otherwise the project directory |
| entry | Optional project-relative .iv entry file; must belong to the discovered source files |
| entries | Optional object from single-word run names to project-relative `.iv` entry files |
| build | Optional object defined below |
| release | Optional deployment object defined below |

The scaffold always writes `entry`, so `foo run` has one unambiguous default.
Existing projects without it retain the conventional `src/main.iv` discovery
rule. `foo run NAME` selects `entries.NAME`; a path can still be supplied for a
one-off run. Entry aliases do not create packages or modules and do not change
visibility.

```sh
foo run
foo run worker
foo run src/maintenance.iv
```

A dependency string is one of the following disjoint forms:

| Form | Resolution |
| --- | --- |
| `1.2.3` | Exact version from the configured registry |
| `^1.2.3` | Compatible version below the next breaking major (with zero-major rules) |
| `~1.2.3` | Compatible patch version within minor 1.2 |
| `path+../library` | A local package path relative to project.json |
| `git+https://host/project.git#COMMIT` | HTTPS Git source at a full 40-hex-digit commit |

Registry dependencies accept exact, caret, and tilde constraints. Tags, branch
names, wildcards, and disjunctions are not valid registry constraints.
`foo add NAME` records a caret constraint from the current release, while
`foo add NAME@VERSION` records the supplied constraint. `foo install` resolves
the manifest and writes the exact selected graph to `foo.lock`.

`foo add NAME PATH` normalizes separators, converts an absolute path to a
project-relative path when possible, and records `path+PATH`. A root local path
is resolved relative to the root `project.json`; a local dependency's own
relative path is resolved relative to that dependency's `project.json`. The
target must contain `project.json`, its `name` must equal NAME, and its `version`
must be exact. That declared version becomes the installed package version.
Installation copies the package into `.foo/packages/NAME` and records the
normalized source plus its current content digest. A later `foo install`
rereads path sources rather than treating a previous local digest as immutable.
Registry packages reachable from the current root and local requirements retain
their locked versions while those versions satisfy every current constraint.

`platformDependencies` keys select an operating system or target prefix, such
as `linux`, `macos`, `windows`, or `wasm`. Development dependencies participate
only in development installs. Optional dependencies participate when a matching
release exists and otherwise do not enter the exact lock.

Applications and unpublished local packages may use external sources. A package
published to the registry must express every published dependency as a registry
version constraint; machine-local paths and mutable external locations cannot
become part of an immutable registry release.

Dependency names bind package identities, not arbitrary source aliases.
Registry identities may be unscoped (`package`) or GitHub-owned
(`@github-login/package`). A publisher cannot claim another account's scope.
Source imports may supply a local alias. A local package's declared name must
match the dependency key. Registry and Git packages additionally bind exact
content digests. A graph requiring two incompatible identities under one
dependency name fails resolution; it does not pick whichever was read first.

## Build options

All build properties are optional; unknown properties are errors.

| Property | Type, default and meaning |
| --- | --- |
| target | Preset name or versioned advanced target object; default host preset |
| optimize | `"dev"` or `"release"`; default dev; both preserve defined semantics |
| output | Project-relative dedicated output directory; default `output` |
| icon | Optional project-relative `.ico` file embedded in Windows executable products |
| coverage | Project-relative path for versioned per-function execution counts; default empty |
| profile | Project-relative path to a version 1 function coverage file consumed by release optimization; default empty |
| docs | Boolean; default false; emit backend documentation plus `docs/api.json` |
| products | Object from single-word product names to product records |
| resources | Array of project-relative glob strings; default empty |
| native | Object from project-relative .iv paths to native-interface dependency names; default empty |
| hooks | Optional root-only `prebuild` and `postbuild` command strings |

Without products, the project builds one executable, selecting the unique
discovered start unless entry selects its file explicitly. A product record has entry
(required relative .iv path), kind (exe/static/shared, default exe), and needs
(array of product names, default empty). It may additionally have soname,
version, exports, script and rpath. Soname and version are nonempty strings;
exports and script are project-relative paths; rpath is an array of target
search-path strings. Platform-inapplicable options are errors.

Only libraries may satisfy needs. Product dependency cycles and links against
an executable are errors. Each executable's source graph contains exactly one
start; a library's graph contains none. Public declarations form its FOO API;
foreign symbol exports use the ABI contract.

Build hooks execute only from the root project's reviewed manifest. Installing
a dependency never executes dependency hooks. A nonzero hook exit status fails
the build, and hook-produced inputs participate in the normal build fingerprint.

```json
{
  "schema": 1,
  "name": "myapp",
  "version": "1.0.0",
  "language": "1",
  "requires": "system",
  "dependencies": { "platform": "path+../platform" },
  "build": {
    "target": ["linux-x64"],
    "output": "output",
    "optimize": "dev",
    "products": {
      "core": { "entry": "core.iv", "kind": "static" },
      "app": { "entry": "main.iv", "needs": ["core"] }
    },
    "resources": ["assets/**/*.txt"],
    "backend": "c",
    "native": { "substrate": "c" }
  }
}
```

`build.native` is an advanced binding for opaque native blocks. Its substrate
is c (system capability) or asm (machine capability). Assembly bindings may
list modified register names in `clobbers`. Both compiler backends support this
binding. Without an explicit selection, native blocks use C. Native payloads
do not implicitly capture FOO locals.

`build.optimize` selects dev or release. Release enables semantic optimization;
dev can opt in with `build.semantic: true`. `build.substrate: "c"` requests
portable C implementations; the default auto selection can use target-specific
implementations when the project capability permits them. Changing these
options invalidates the affected cached IR or emission.

`build.coverage` instruments functions and writes a version 1 JSON profile at
normal process completion. A later release build may set `build.profile` to
that file. Profile contents participate in artifact identity, and malformed,
missing, or incompatible profiles are build errors rather than silent fallbacks.

When `build.docs` is true, both backends write `docs/api.json`. The document has
format `foo.docs`, version 1, the module name, and arrays describing public,
foreign, and start functions plus declared types. A backend may place additional
native documentation beside this portable index.

## Release staging and command links

The optional `release` object has `directory` (a dedicated project-relative
staging directory, default `release`), `icon`, `license`, `readme`, `files`, and
`sign`. The four file selections are project-relative; `files` is an array and
the others are strings. `sign` contains `provider` and an optional `timestamp`.
Provider is `auto`, `gpg`, `authenticode`, or `codesign`. Signing identities and
private credentials are environment inputs and are never manifest values.

`foo release` requires this object, selects release optimization, builds the
configured products, and stages one `NAME-VERSION-TARGET` directory. It writes
a versioned `foo.release` metadata document and SHA-256 checksums. `--sign`
signs staged executable and shared-library artifacts before checksums are
produced; static archives are not signed automatically. `foo sign ARTIFACT`
applies the same provider contract to an existing executable.

`foo link [ENTRY] [--name COMMAND]` creates a launcher in `FOO_BIN`, or
`~/.foo/bin` when unset. The launcher runs the validated default or named entry
from its project root. `foo unlink COMMAND` removes exactly that launcher.
`foo path` prints the bin directory; linking does not mutate the operating
system's `PATH` configuration. Launchers forward arguments through the
`foo run ENTRY -- ARGUMENTS` boundary without reinterpreting them as FOO CLI
options.

An optional `tests` object maps test fixture filenames, without `.iv`, to native
fixture options. `tests.NAME.sources` is a list of project-relative C source
paths linked only for that fixture. Common C include paths and sources still
come from `build.c`. Fixtures use the project's declared capability level.

Globs use `*` within one path segment, `?` for one non-separator character,
and `**` for zero or more complete segments. Resource results are sorted by
normalized relative path and duplicates removed. Absolute paths and traversal
outside the package are invalid resource selections.

## Dependency lock and capability closure

`foo.lock` is JSON with format `foo.lock`, version 1, the registry index
revision when a registry was used, and a packages array sorted by package
identity. Every package entry records its name, exact version, source locator,
content digest, direct status, and exact dependency identities. Registry source
bundles are immutable (cannot change at the same version). Local path sources
are development inputs: reinstalling rereads them and rewrites their digest.
The repository URL and commit remain provenance metadata for registry entries.

The project's requires value is an upper bound on the capabilities its source
and dependency interfaces may require. A higher-level dependency is an error
with an explicit required-level diagnostic; it never silently upgrades the
project. Installation is described in [toolchain](toolchain.md).

Completed executable, static-library and shared-library products reside under
`build.output`, which defaults to `output`. FOO creates missing output
directories. The path is confined to the project and must not overlap source,
test, benchmark, dependency, cache, or compiler-work directories. Generated
bindings, resource bundles, dependency material, backend intermediates and
caches reside under `.artifacts/`. Output products do not participate in the
project build fingerprint or resource globs.

Application sources live under `src/`, tests under `test/`, and executable
benchmark scenarios under `benchmark/` by convention. Sources, locks and
reviewed configuration are permanent project files. `foo clean` removes both
the configured product directory and internal build state. Watch observes source/configuration/dependency
changes, keeps reporting diagnostics after errors, and reuses results only when
their semantic inputs and contracts are unchanged.
