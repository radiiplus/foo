# Foo registry

This directory contains the registry UI, the Git-backed registry data, and the Supabase Edge Function used for authenticated writes.

## Local development

Install the workspace dependencies from this directory:

```sh
npm install
```

Start the Vite UI:

```sh
npm run dev:ui
```

The UI runs at `http://localhost:5173`. During development, Vite serves the local `repository/` tree at `/registry-data`; production reads the same manifest, index shards, and package records directly from [`radiiplus/foo.registry`](https://github.com/radiiplus/foo.registry). Set `VITE_REGISTRY_URL` to point the UI at another compatible registry source.

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

The registry data repository contains expanded canonical records in `packages/` and generated JSONL discovery shards in `indexes/`. Each record carries a structured public API surface for the web explorer. `scripts/standard.mjs` indexes every bundled standard module as `std/<module>`; `scripts/index.mjs` normalizes and shards the combined catalog.

## CLI flow

The compiler reads discovery data directly from the GitHub repository. `foo search` matches package metadata and exported public symbols from the generated shards. Run `foo login` once, `foo init [directory]` to scaffold a publishable package, and `foo publish` from a clean Git checkout. Add dependencies with `foo add package` or `foo add package@version`, then run `foo install` to resolve the manifest. Use `foo update`, `foo outdated`, and `foo remove` to manage the locked graph.

Every release includes the formatted Foo source files, their digest, and a compiler-generated `foo.api/v1` index of public modules, types, functions, constants, and values. Installation verifies and extracts the source bundle under `.foo/packages/`; an existing `foo.lock` replays exact versions and verifies every digest. `foo deprecate package@version message` marks a release without deleting it.

## Tests

`npm test` exercises the local Git-backed discovery API and shared publication handler. `npm run test:deno` runs the handler routing tests with Deno.
