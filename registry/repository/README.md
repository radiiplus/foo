# FOO Registry

The official package catalog for the [FOO programming language](https://github.com/radiiplus/foo).

This repository is where FOO's standard library and published community packages are made available. Use it to discover libraries, review what they provide, and install them in your FOO projects.

New to the language? Visit the [main FOO repository](https://github.com/radiiplus/foo) for installation, documentation, examples, and releases.

## Quick usage

Find a package:

```sh
foo search http
foo info std/json
foo info package-name
```

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
