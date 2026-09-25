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
| build | Optional object defined below |

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

`platformDependencies` keys select an operating system or target prefix, such
as `linux`, `macos`, `windows`, or `wasm`. Development dependencies participate
only in development installs. Optional dependencies participate when a matching
release exists and otherwise do not enter the exact lock.

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
revision, and a packages array sorted by package identity. Every registry
package entry records its name, exact version, immutable registry source
bundle, content digest, direct status, and exact dependency identities. The
repository URL and commit remain provenance metadata.

The project's requires value is an upper bound on the capabilities its source
and dependency interfaces may require. A higher-level dependency is an error
with an explicit required-level diagnostic; it never silently upgrades the
project. Installation is described in [toolchain](toolchain.md).

Generated binaries, generated bindings, resource bundles, dependency material
and caches reside under `.artifacts/`. Sources, locks and reviewed configuration
are permanent project files. Watch observes source/configuration/dependency
changes, keeps reporting diagnostics after errors, and reuses results only when
their semantic inputs and contracts are unchanged.
