# Packages

`project.json` is version 1 and names the package, language, capability level, entry point, and dependencies:

```json
{
  "name": "app",
  "version": "1.0.0",
  "language": "1",
  "requires": "base",
  "dependencies": { "http": "^1.2.0" }
}
```

`foo add`, `foo remove`, `foo update`, and `foo install` manage dependencies. The lockfile records the exact versions selected. `foo publish` signs a package; `foo audit` checks that it has not been changed. Package names come from the package name and the relative `.iv` path.

## The shape of a project

```text
myapp/
  project.json
  src/
    main.iv
    screen.iv
  test/
    app.iv
```

`src` holds code that belongs in the program. `test` holds checks. Files do not need an index file: FOO finds `.iv` files itself and gives each one a name based on its path.

## Version numbers

The first number means a change that may require code changes. The second means a new compatible feature. The last means a correction. A dependency such as `^1.2.0` permits compatible updates within version 1; the lockfile still records the exact version used by the build.

## Private and public code

Keep helpers private by default. Export only the functions and types that form the package's promise:

```iv
function trim_spaces(value of type text) of type text { give value. }
public function clean(value of type text) of type text {
  give trim_spaces(value).
}
```

Another package may call `clean`, but it cannot depend on `trim_spaces`.

## A manifest in plain words

`name` identifies the package. `version` tells users which release they have. `language` prevents a new compiler from guessing at an old file format. `requires` says which computer abilities the package needs. `dependencies` lists other packages and their allowed versions.

When you run `foo install`, FOO reads this file, downloads the requested packages, checks their recorded fingerprints, and stores the result in the cache. The lockfile records the exact choice so another computer can repeat it.

## Publishing safely

`foo publish` signs the package before sending it. `foo audit` checks the signature and every recorded file. If a downloaded package was changed, the audit stops and names the changed file.
