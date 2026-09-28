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
`std/` prefix.

The alias controls the qualifier (the name written before the dot) used in the
file:

```foo
constant content is files.read("notes.txt") try.
```

## Import another project file

Use a quoted path relative to the importing module:

```foo
use "billing/tax.iv" as tax.

constant total is tax.add(100.0, 5.0).
```

The imported declaration must be public:

```foo
-- src/billing/tax.iv
public function add(price decimal, amount decimal) giving decimal {
  give price plus amount.
}
```

Declarations without `public` remain private to their file. An ordinary import
does not automatically re-export anything.

## Build a facade module (one public entry point over internal modules)

Use `public use` for a transparent facade (a module presenting a simpler public
surface over internal modules) that preserves the imported public
names:

```foo
-- src/account.iv
public use "internal/storage.iv".
```

The compiler reports collisions between local declarations and names that are
re-exported (made public again from another module). A public use cannot have an
alias. Publish a forwarding function when
the facade must rename or adapt an operation:

```foo
-- src/account.iv
use "internal/storage.iv" as storage.

public function lookup(name text) giving failable storage.User {
  give storage.lookup(name) try.
}
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
stored as `path+...` entries in `project.json`.

## If a package is not installed

`use packageName.` does not silently download code during a build. If the
package is declared but missing locally, checking stops with an installation
diagnostic. Run:

```sh
foo install
```

If it is not declared, add it first:

```sh
foo add packageName
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

1. A sibling project file.
2. A file under the project's source root.
3. A declared and installed package.
4. A standard-library module.

Name collisions and circular imports are compile errors.

## Common mistakes

| Problem | Fix |
| --- | --- |
| Writing `use std/file.` | Write `use file.` or give it an alias. |
| A declaration is invisible | Add `public` in the defining module. |
| Package source is unavailable | Run `foo install` before checking. |
| Depending on a Git branch | Pin a full commit for reproducibility. |
| Expecting an import to be re-exported | Add a deliberate public forwarding function. |

Next: [Projects and entry points](projects.md).
