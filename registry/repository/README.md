# FOO Registry

The official package catalog for the [FOO programming language](https://github.com/radiiplus/foo).

This repository stores published community packages. Standard library modules are generated from `lib/*.iv` in the [FOO repository](https://github.com/radiiplus/foo/blob/main/registry/standard.json) and read by the registry directly.

New to the language? Visit the [main FOO repository](https://github.com/radiiplus/foo) for installation, documentation, examples, and releases.

## Quick usage

Find a package:

```sh
foo search http
foo info lib/json
foo info package-name
```

Bundled modules use the reserved `lib/` namespace in the public index.

Add and install a package:

```sh
foo add package-name
foo install
```

Check for and install compatible updates:

```sh
foo outdated
foo update package-name
```

Create and publish a package:

```sh
foo login
foo init my-package
cd my-package
foo publish
```
