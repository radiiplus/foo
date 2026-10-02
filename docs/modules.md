# Modules and Packages

Every `.iv` file is a module. Modules organize source code; packages organize
versioned dependencies.

## Import a standard module

```foo
use file as files.
use sequence as sequences.
use http as web.
```

Standard modules use their plain names. Application code does not write a
`lib/` prefix.

The alias controls the qualifier (the name written before the dot) used in the
file. Without `as`, the module's own name is the qualifier, so both
`use sequence.` and `use sequence as sequences.` are valid:

```foo
use file as files.

constant content is files.read("notes.txt") try.
```

## Import another project file

Use a quoted path relative to the importing module. This fragment assumes the
next example is stored at `src/billing/tax.iv`:

<!-- snippet: project tax src/main.iv -->
```foo
use "billing/tax.iv" as tax.

constant total is tax.add(100.0, 5.0).
```

The imported declaration must be public. This is the other file in the same
checked example:

<!-- snippet: project tax src/billing/tax.iv -->
```foo
-- src/billing/tax.iv
public function add(price decimal, amount decimal) giving decimal {
  give price plus amount.
}
```

Declarations without `public` remain private to their file. An ordinary import
does not automatically re-export anything.

Public records may contain concrete generic types imported from another
module. That specialization is part of the record's public layout and is
supported by both native backends:

<!-- snippet: project genericfield src/core.iv -->
```foo
public define Reference as record {
  number of type integer.
}.
```

<!-- snippet: project genericfield src/store.iv -->
```foo
use map as maps.
use core.

public define Store as record {
  values of type maps.Map[text, core.Reference].
}.
```

<!-- snippet: project genericfield src/main.iv -->
```foo
use store.

start {}
```

## Build a facade module (one public entry point over internal modules)

Use `public use` for a transparent facade (a module presenting a simpler public
surface over internal modules) that preserves the imported public names:

<!-- snippet: project facade src/internal/storage.iv -->
```foo
public function lookup(name text) giving text { give name. }
```

<!-- snippet: project facade src/account.iv -->
```foo
-- src/account.iv
public use "internal/storage.iv".
```

<!-- snippet: project facade src/main.iv -->
```foo
use account.

display account.lookup("Ada").
```

The compiler reports collisions between local declarations and names that are
re-exported (made public again from another module). A public use cannot have an
alias. Publish a forwarding function when the facade must rename or adapt an
operation:

<!-- snippet: project wrapper src/internal/storage.iv -->
```foo
public function lookup(name text) giving failable text { give name. }
```

<!-- snippet: project wrapper src/account.iv -->
```foo
-- src/account.iv
use "internal/storage.iv" as storage.

public function lookup(name text) giving failable text {
  give storage.lookup(name) try.
}
```

<!-- snippet: project wrapper src/main.iv -->
```foo
use account.

display(account.lookup("Ada") fallback "missing").
```

Callers use `account.lookup`. The wrapper is a new public contract, so document
its failure and ownership behavior. It does not make every declaration from
`storage` public.

## Add a registry package

```sh
foo add http-client
foo install
```

Choose a particular version or constraint when needed:

```sh
foo add http-client@1.2.0
foo add http-client@^1.2.0
```

The registry is configured by the toolchain. Users do not write an internal
`registry+...` identifier for an ordinary package install.

## Add a URL or local package

Give the dependency a local name and provide its source:

```sh
foo add parser https://github.com/example/parser.git#0123456789012345678901234567890123456789
foo add shared ..\shared
```

Git dependencies use an immutable (unchangeable) full commit. Local paths are normalized and
stored as `path+...` entries in `project.json`. An absolute path is converted
to a project-relative path when the two locations permit it. A local path is resolved from
the directory containing the `project.json` that declares it. Therefore the
same dependency is written on Linux and macOS as:

```sh
foo add shared ../shared
```

`foo install` reads the local package's exact `version` from its own
`project.json`, checks that its declared `name` matches `shared`, copies the
package under `.foo/packages/shared`, and records its source digest (a content
fingerprint) in `foo.lock`. A local package may use another relative local path;
that nested path is resolved from the local package that declares it. Running
`foo install` again rereads local sources and refreshes their lock entries while
preserving registry versions already selected by the reachable lock graph.

Install the package as a whole. You do not name one feature or internal file in
`foo add`. After installation, `use shared.` opens the package's configured
public `entry`, or `<source>/main.iv` when no entry is configured. Only public
declarations reachable from that entry are available. A package should use a
facade module (one public entry that re-exports its supported API) when it has
several internal source files.

## If a package is not installed

`use package.` does not silently download code during a build. If the
package is declared but missing locally, checking stops with an installation
diagnostic. Run:

```sh
foo install
```

If it is not declared, add it first:

```sh
foo add package
foo install
```

This separation keeps builds reproducible (the same inputs produce the same
dependency setup) and prevents source code from
triggering unexpected network access.

## Lock files

`foo install` writes `foo.lock` with exact versions, content digests (short
fingerprints used to verify content), and the resolved dependency graph (the
full tree of packages and the packages they need). Commit it for applications so another machine can
reproduce the same graph.

## Finding and updating packages

```sh
foo search json
foo info json
foo outdated
foo update
foo update json
foo remove json
```

## Import resolution

A bare import is resolved in this order:

1. A sibling project file other than the importing file itself.
2. A same-named file directly under the project's configured source root.
3. A declared and installed package.
4. A standard-library module.

Quoted imports are resolved relative to the importing file and do not use this
search order. Name collisions and circular imports are compile errors. Thus a
test file can write `use values.` to import `src/values.iv`, while
`test/values.iv` cannot use that spelling to import itself.

## Common mistakes

| Problem | Fix |
| --- | --- |
| Writing `use lib/file.` | Write `use file.` or give it an alias. |
| A declaration is invisible | Add `public` in the defining module. |
| Package source is unavailable | Run `foo install` before checking. |
| Depending on a Git branch | Pin a full commit for reproducibility. |
| Expecting an import to be re-exported | Add a deliberate public forwarding function. |

Next: [Projects and entry points](projects.md).
