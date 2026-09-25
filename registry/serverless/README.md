# Foo publication function

This Supabase Deno Edge Function is the registry's only write path. It keeps no database or server-side session state.

## Authentication

`GET /auth/github` starts GitHub's OAuth authorization-code flow with a Firebase callback and PKCE challenge. The function accepts only callbacks listed in `GITHUB_OAUTH_CALLBACKS` and places the callback and challenge in signed state that expires after ten minutes. It stores no cookie or server session.

GitHub redirects to the Firebase `/auth/callback` page. The page sends the returned code and state, its original PKCE verifier, and the same callback URL to `POST /auth/exchange`. The function verifies all four values before exchanging the code for a GitHub token.

Clients send that token as `Authorization: Bearer <token>` when publishing. Every publication revalidates it against GitHub's authenticated-user endpoint. The numeric GitHub ID exists only in memory long enough to derive `HMAC-SHA256(OWNERSHIP_SECRET, "github:" + id)`; records store the resulting versioned opaque ownership signature and display login, never the numeric ID. An `owner`, `github_id`, or any other unknown manifest field is rejected.

`OAUTH_STATE_SECRET` and `OWNERSHIP_SECRET` have separate jobs. The state secret authenticates the short-lived OAuth callback payload, including its callback URL, PKCE challenge, nonce, and expiry, so it cannot be forged or redirected. The ownership secret deterministically pseudonymizes GitHub IDs for permanent registry authorization. Do not reuse or casually rotate either key; ownership-key rotation requires migrating all stored owner signatures.

Configure these deployment secrets:

```text
GITHUB_CLIENT_ID
GITHUB_CLIENT_SECRET
GITHUB_OAUTH_CALLBACKS=https://your-project.web.app/auth/callback
OAUTH_STATE_SECRET
OWNERSHIP_SECRET
GITHUB_TOKEN
GITHUB_REPOSITORY=radiiplus/foo.registry
GITHUB_BRANCH=main
REGISTRY_SOURCE=https://raw.githubusercontent.com/radiiplus/foo.registry/main
```

`GITHUB_TOKEN` is the server credential for the registry repository and requires repository Contents write permission. It is never supplied by a publishing user.

Authenticate and deploy with the Supabase CLI:

```sh
supabase login
npm run deploy
```

The deploy script uses Supabase's server-side bundler, so deployment does not require Docker. The checkout must be linked to the target project and the secrets above must already be configured there. In CI, set `SUPABASE_ACCESS_TOKEN` instead of running the interactive login command.

## Publication

`POST /publish` accepts:

```json
{
  "schema": "foo.publish/v1",
  "manifest": {
    "schema": "foo.package/v1",
    "name": "foo-example",
    "version": "1.0.0",
    "description": "Example package.",
    "category": "Developer Tools",
    "tags": ["example"],
    "license": "MIT",
    "compatible": true,
    "deprecated": "",
    "platforms": ["linux"],
    "updated": "2026-09-25",
    "repository": "https://github.com/example/foo-example",
    "revision": "0123456789abcdef0123456789abcdef01234567",
    "install": "foo add foo-example",
    "dependencies": []
  },
  "documentation": ["At least 100 non-empty lines"],
  "source": {
    "format": "foo.source/v1",
    "digest": "server-recomputed-sha256",
    "files": [
      { "path": "src/main.iv", "content": "public constant answer is 42.\n" }
    ]
  },
  "api": {
    "schema": "foo.api/v1",
    "modules": [{
      "name": "main",
      "path": "src/main.iv",
      "summary": "",
      "items": [{ "kind": "constant", "name": "answer", "declaration": "public constant answer.", "documentation": "" }]
    }]
  }
}
```

The function validates and normalizes metadata, source, and compiler-generated public API metadata without executing package code. It recalculates the source digest, ensures API modules refer to bundled Foo files, reads the current Git commit and registry index, compares the authenticated user's derived ownership signature in constant time, regenerates deterministic JSONL shards in memory, and advances the branch with one atomic Git commit. Non-fast-forward publication races return `409` for a safe retry.

Unscoped names have one owner. When another publisher already owns the same package basename, publication returns `409` and requires `@github-login/package`. A scoped name must match the authenticated GitHub login.

`POST /deprecate` accepts an authenticated `{ "name", "version", "message" }` body. It updates the release and index metadata in a new Git commit without deleting the package or its source.

## Discovery

`GET /search`, `/package/:name`, `/category/:category`, `/tag/:tag`, and `/resolve/:package` read only the generated Git index and canonical package records. Responses include schema identifiers, the registry revision, complete metadata, deterministic ordering, pagination, and category/tag facets. No discovery state is stored by the function.

The registry repository must contain an initial commit before deployment. Apply the Patch 1 foundation files to `radiiplus/foo.registry` first.
