# Foo registry

This directory contains the registry UI, the community package data tools, and the Supabase Edge Function used for authenticated writes. Bundled standard modules come from `registry/standard.json` in the FOO repository, generated from `lib/*.iv` with `npm run registry:standard` at the repo root. Run `npm run registry:standard:check` in CI or before publishing FOO changes; it fails when that catalog is stale.

## Local development

Install the workspace dependencies from this directory:

```sh
npm install
```

Start the Vite UI:

```sh
npm run dev:ui
```

The UI runs at `http://localhost:5173`. During development, Vite serves the sibling `foo.registry` checkout at `/registry-data` when present, and this repo's standard catalog at `/foo-data`. Production reads community releases from [`radiiplus/foo.registry`](https://github.com/radiiplus/foo.registry) and standard modules from [`radiiplus/foo`](https://github.com/radiiplus/foo). Set `VITE_REGISTRY_URL` and `VITE_FOO_SOURCE_URL` to use other compatible sources.

Browser routes use clean paths: `/registry` opens discovery, `/standard` opens the complete standard-library declaration reference, `/package/:package` opens a package and its public API, `/docs/:chapter` opens the FOO Book, and `/downloads` lists release packages. The hosting fallback serves `index.html` for direct visits to those paths, and legacy `/#/...` links redirect to their clean equivalent.

`npm run dev:api` remains available for testing compatibility endpoints and the publication handler, but the UI and compiler do not depend on it for reads.

## Supabase

The deployable project is in `serverless`. To run it with the Supabase runtime (Docker required):

```sh
cd serverless
npm run dev
```

Deploy the function after linking the project:

```sh
cd serverless
npm run deploy
```

The function is the authenticated write plane. It validates GitHub tokens for publication, converts the stable numeric GitHub ID into a deterministic HMAC ownership pseudonym, and advances `radiiplus/foo.registry` with one atomic Git commit containing the canonical release and regenerated indexes. Raw GitHub IDs are not stored. The compiler, registry website, and external indexers use the public Git repository as the read plane. Configure the source and repository credentials described in `serverless/.env.example`.

The function exposes the following authenticated routes and compatibility read routes:

- `GET /health`
- `GET /search?q=...`
- `GET /package/:name?version=...`
- `GET /category/:category`
- `GET /tag/:tag`
- `GET /resolve/:package?version=...`
- `GET /auth/github` and `POST /auth/exchange` for the Firebase web OAuth callback
- `POST /auth/device` and `POST /auth/device/token` for `foo login`
- `POST /publish`
- `POST /deprecate`

The registry data repository contains community records in `packages/` and generated JSONL discovery shards in `indexes/`. The FOO repository's generated standard catalog carries bundled modules under `lib/<module>`, including their public API and source digest. The website and discovery API merge both sources at read time.

## CLI flow

The compiler reads community discovery data from `foo.registry` and standard modules from FOO's catalog. Set `FOO_REGISTRY_URL` and `FOO_SOURCE_URL` to override those read roots. `foo search` matches package metadata and exported public symbols from both sources. Run `foo login` once, `foo init [directory]` to scaffold a publishable package, and `foo publish` from a clean Git checkout. Add dependencies with `foo add package` or `foo add package@version`, then run `foo install` to resolve the manifest. Use `foo update`, `foo outdated`, and `foo remove` to manage the locked graph.

Every release includes the formatted Foo source files, their digest, and a compiler-generated `foo.api/v1` index of public modules, types, functions, constants, and values. Installation verifies and extracts the source bundle under `.foo/packages/`; an existing `foo.lock` replays exact versions and verifies every digest. `foo deprecate package@version message` marks a release without deleting it.

Set `"icon": "assets/icon.svg"` in a package's `project.json` to publish an optional icon. The path must be relative to the package root and the file must be at most 64 KiB. The registry accepts basic SVG shapes and paint attributes, rejects scripts, links, styles, embedded content, and external references, and stores a canonical SVG in the package record and search index. The website renders icons only through image elements, so the SVG is never inserted into the page DOM as markup. Packages without an icon use the standard package symbol.

## Tests

`npm test` exercises the local Git-backed discovery API and shared publication handler. `npm run test:deno` runs the handler routing tests with Deno.
