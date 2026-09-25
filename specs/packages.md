# Packages
Version: 1.

## Files and visibility
Every .iv file is a compilation unit and a namespace. Its namespace is the
package name followed by its path relative to the source root, without .iv,
joined by `::`. For example, src/network/server.iv in myapp has namespace
`myapp::network::server`. Source locations retain the .iv suffix. Absolute host
paths do not participate in public names. Paths differing only by ASCII case
are rejected so names remain portable.

Declarations are private unless prefixed with `public`. Public functions, constants, dynamic values and types form the file's interface. Imports are private bindings; importing a file does not re-export it. A public signature can mention only publicly reachable types and capabilities. A file cannot access another file's private declarations.

```iv
-- Arithmetic operations.
public function add(left integer, right integer)
  giving integer {
  give left plus right.
}
```

A caller imports that file and qualifies its members:

```iv
-- Application entry.
use "./arithmetic.iv" as arithmetic.

start() {
  constant total is arithmetic.add(20, 24).
  give nothing.
}
```

There is no module wrapper or namespace block. The module keyword produces a
migration diagnostic explaining how to remove the wrapper.

## Import resolution
`use name.` binds namespace name and its public declarations. An explicit alias
imports only qualified names. Resolve a bare name in this order: a sibling
name.iv, a source-root name.iv, a declared dependency named name, then a standard
library module named name. The first existing candidate wins; errors in that
candidate do not trigger fallback. An unqualified import collision is an error;
an alias disambiguates it.

A quoted file path includes .iv and resolves from the importing file, including
paths such as `use "network/server.iv".`. A quoted package name contains a
namespace separator, such as `use "web/http".`, and must exactly match a declared
dependency. Single-word package names use the bare form.
Nested standard modules also use a quoted name, such as `use "os/unix".`;
declared dependencies take precedence over bundled modules with the same name.

A dependency's public entry is main.iv under its source root, unless its entry
setting selects another file. Without as, a relative import uses the file stem
and a package uses its final name segment. An explicit alias supplies a simpler local
name. Two imports cannot bind the same name, and an import cannot collide with
a local declaration. An alias changes neither visibility nor identity.

Imports precede no mandatory section: they may appear anywhere at file scope, and their scope is the entire file. Import cycles are errors. Each canonical file is analyzed once per configuration regardless of how many paths reach it.

Source discovery scans every .iv file below the configured source root. It
does not require directory index files. Generated artifacts, dependency storage,
version-control directories and installed JavaScript dependencies are excluded.
All discovered files are checked, including files not imported by the entry.
Dependency order places imported units before their consumers.

`foo graph` emits JSON with format foo.graph, version 1, units and order. Each
unit records namespace, package, source-relative path, entry status, imported
namespaces and symbols with public/private visibility. Order lists namespaces
with dependencies first. Missing imports have FOO codes and, where a nearby
candidate exists, a did-you-mean suggestion. Import cycles use FOO0012 and
identify the offending use and dependency chain.

## Dependencies
[Project configuration](project.md) defines dependency sources, versions and locks. Resolution chooses one version per registry package identity in a project graph; incompatible requirements are errors. Local packages retain distinct identities even if their file stems match.

Dependencies provide FOO interfaces. A package requiring native support must declare its capability requirement and target contracts; it cannot expose a substrate-specific type through an ordinary public API. The effective installation requirement is the greatest requirement in the reachable dependency graph, bounded by the application's declared level.

Downloaded package contents are verified against their locked digest before use. Installation does not execute dependency hooks. Verification failure is an error, never permission to accept an unverified substitute.
