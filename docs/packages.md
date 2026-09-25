# Chapter 8: Packages

Foo's package registry is a public Git repository. Package records live under `packages/`, while deterministic discovery shards live under `indexes/`. Package search and installation read those files directly from GitHub; the serverless service is used only for GitHub authentication and publication.

## Creating a package

```sh
foo init my-package
cd my-package
```

The scaffold contains `project.json`, `README.md`, `src/main.iv`, and `.gitignore`. Before publication, set the repository URL and package metadata in `project.json`, write at least 100 non-empty lines of documentation, and commit every source change.

## Authentication and publication

```sh
foo login
foo publish
```

`foo login` uses GitHub's device flow and stores the resulting token in the user's Foo configuration directory. GitHub leaves its device authorization page open after approval, so return to the terminal once authorization succeeds. `foo publish` first checks the package with the compiler, then reports its packaging and upload stages. It formats and bundles the Foo source alongside metadata and documentation. The package README remains author-owned: publication reads it without generating or rewriting the local file, and the registry materializes its browsable mirror from that content. Separately, the compiler derives a `foo.api/v1` JSON index from the AST and adjacent source comments, so every release records the library modules, types, functions, constants, values, signatures, and API documentation it exposes. The serverless endpoint validates the token with GitHub, derives a stable opaque HMAC ownership signature from the numeric GitHub ID, discards the raw ID, checks ownership, verifies the bundle digest and API paths, and commits the immutable expanded release record plus the browsable README/source mirror to the registry repository. It never executes package code.

The published release points to the repository and the full Git commit SHA from the clean local checkout. Published versions cannot be replaced.

An unscoped name belongs to its first publisher. If that basename is already owned by someone else, publish under `@github-login/package`; the scope must match the GitHub account authenticated by `foo login`.

## Finding packages

```sh
foo search http
foo info foo-http
foo info foo-http@1.4.2
```

These commands read the public index shards and package records without calling the serverless function.

The registry website reads the same public Git manifest, shards, and package records as the compiler; discovery does not pass through the publication service. It searches packages, standard modules, and exported symbol names. Every bundled standard module is indexed under `std/<module>` and appears in the default catalog. Open `/package/:package` directly to browse a release and filter its public API; for example, `/package/foo-http` or `/package/std%2Fjson`. These are normal browser paths, not hash routes.

## Adding dependencies

```sh
foo add foo-http
foo add foo-http@1.4.2
foo add local-tools ../local-tools
foo add widgets https://github.com/example/widgets.git
```

The registry is configured internally. Use `name` or `name@version` for a
registry package; do not write an internal `registry+...` locator. The optional
second argument is reserved for an external URL, Git repository, or local path.

`foo add foo-http` selects the current indexed release. Exact versions and
compatible `^` or `~` constraints are also accepted. The dependency is written
to `project.json`; install the complete graph afterward:

```sh
foo install
```

FOO resolves runtime dependencies transitively, applies development, optional,
and platform constraints, and rejects incompatible graphs. It verifies and
extracts the source bundle stored in each canonical registry record. Resolution
chooses one compatible version per package and records the exact result in the
lockfile.

Installed sources live under `.foo/packages/`. The generated `foo.lock` is deterministic and records the registry revision, exact package version, source digest, direct status, and dependency identities for every package. Adding, removing, or changing a dependency constraint directly in `project.json` makes `foo install` resolve the changed graph and rewrite the lockfile. An unchanged manifest installs from the lock exactly; `foo update` resolves newer compatible releases within the existing constraints, `foo outdated` reports them, and `foo remove` prunes the graph.

Registry indexes are sharded for large package counts. Release metadata can
mark versions deprecated, provide mirrors, and carry platform compatibility;
installation still verifies the canonical bundle digest. Owners can deprecate a
version with `foo deprecate package@version message`; the source remains
available so existing lockfiles never break.
