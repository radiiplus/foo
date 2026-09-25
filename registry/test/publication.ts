import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { after, test } from "node:test";
import { promisify } from "node:util";

import { createLocalDeprecator, createLocalPublisher } from "../local.ts";
import { handleRequest } from "../serverless/supabase/functions/_shared/handler.ts";
import { registryOwner } from "../serverless/supabase/functions/_shared/identity.ts";

process.env.OWNERSHIP_SECRET = "test-ownership-secret-with-at-least-32-characters";

const execute = promisify(execFile);
const temporary: string[] = [];

after(async () => {
  await Promise.all(temporary.map((path) => rm(path, { recursive: true, force: true })));
});

test("an authenticated publication creates a registry commit", async () => {
  const repository = await mkdtemp(join(tmpdir(), "foo-publication-"));
  temporary.push(repository);
  await cp(resolve("repository"), repository, { recursive: true });
  await git(repository, "init", "-b", "main");
  await git(repository, "config", "user.name", "foo-registry-test");
  await git(repository, "config", "user.email", "foo-registry-test@example.invalid");
  await git(repository, "add", ".");
  await git(repository, "commit", "-m", "foundation");
  const before = await git(repository, "rev-parse", "HEAD");
  const foundation = JSON.parse(await readFile(join(repository, "indexes", "index.json"), "utf8")) as { count: number };

  const publishRequest = new Request("http://localhost/functions/v1/registry/publish", {
    method: "POST",
    headers: { authorization: "Bearer valid-github-token", "content-type": "application/json" },
    body: JSON.stringify(submission("foo-lines", "Documentation")),
  });
  const response = await handleRequest(publishRequest, createLocalPublisher(repository), async (incoming) => {
    assert.equal(incoming.headers.get("authorization"), "Bearer valid-github-token");
    return { id: 152736140, login: "radiiplus" };
  });
  const body = await response.json() as { commit: string; path: string; owner: string };

  assert.equal(response.status, 201);
  assert.equal(body.owner, "radiiplus");
  assert.equal(body.path, "packages/foo-lines/1.0.0.json");
  assert.notEqual(body.commit, before);
  assert.equal(await git(repository, "log", "-1", "--pretty=%s"), "publish foo-lines@1.0.0");
  const stored = JSON.parse(await readFile(join(repository, "packages", "foo-lines", "1.0.0.json"), "utf8"));
  assert.deepEqual(stored.owner, await registryOwner({ id: 152736140, login: "radiiplus" }));
  assert.equal(JSON.stringify(stored).includes("152736140"), false);
  assert.equal(stored.revision, "0123456789abcdef0123456789abcdef01234567");
  assert.equal(stored.readme.length, 100);
  assert.equal(stored.kind, "package");
  assert.equal(stored.api.modules[0].items[0].name, "answer");
  assert.match(await readFile(join(repository, "packages", "foo-lines", "1.0.0", "README.md"), "utf8"), /Documentation line 100/);
  assert.equal(await readFile(join(repository, "packages", "foo-lines", "1.0.0", "source", "src", "main.iv"), "utf8"), "public constant answer is 42.\n");
  const manifest = JSON.parse(await readFile(join(repository, "indexes", "index.json"), "utf8"));
  assert.equal(manifest.count, foundation.count + 1);

  const duplicate = await handleRequest(request(submission("foo-lines", "Documentation")), createLocalPublisher(repository), async () => ({ id: 152736140, login: "radiiplus" }));
  assert.equal(duplicate.status, 409);
  assert.match((await duplicate.json() as { error: string }).error, /already exists/);

  const next = submission("foo-lines", "Documentation");
  next.manifest.version = "1.1.0";
  const unauthorized = await handleRequest(request(next), createLocalPublisher(repository), async () => ({ id: 99, login: "other-user" }));
  assert.equal(unauthorized.status, 409);
  assert.match((await unauthorized.json() as { error: string }).error, /@other-user\/foo-lines/);
  assert.equal(await git(repository, "rev-parse", "HEAD"), body.commit);

  const scoped = await handleRequest(request(submission("@other-user/foo-lines", "Documentation")), createLocalPublisher(repository), async () => ({ id: 99, login: "other-user" }));
  assert.equal(scoped.status, 201);
  assert.equal((await scoped.json() as { path: string }).path, "packages/@other-user/foo-lines/1.0.0.json");

  const ownerUpdate = await handleRequest(request(next), createLocalPublisher(repository), async () => ({ id: 152736140, login: "radiiplus" }));
  assert.equal(ownerUpdate.status, 201);

  const deprecation = await handleRequest(new Request("http://localhost/functions/v1/registry/deprecate", {
    method: "POST",
    headers: { authorization: "Bearer token", "content-type": "application/json" },
    body: JSON.stringify({ name: "foo-lines", version: "1.0.0", message: "Use 1.1.0 instead." }),
  }), createLocalPublisher(repository), async () => ({ id: 152736140, login: "radiiplus" }), undefined,
  createLocalDeprecator(repository));
  assert.equal(deprecation.status, 200);
  const deprecated = JSON.parse(await readFile(join(repository, "packages", "foo-lines", "1.0.0.json"), "utf8"));
  assert.equal(deprecated.deprecated, "Use 1.1.0 instead.");
  assert.equal(await git(repository, "log", "-1", "--pretty=%s"), "deprecate foo-lines@1.0.0");
});

test("publication rejects owner fields and short documentation", async () => {
  const short = submission("foo-short", "Documentation");
  short.documentation.length = 99;
  const response = await handleRequest(request(short), async () => ({ path: "unused", commit: "unused" }), async () => ({ id: 1, login: "user" }));
  assert.equal(response.status, 400);
  assert.match((await response.json() as { error: string }).error, /at least 100 lines/);

  const spoofed = submission("foo-spoofed", "Documentation") as ReturnType<typeof submission> & { manifest: Record<string, unknown> };
  spoofed.manifest.owner = { id: 2, login: "attacker" };
  const spoofedResponse = await handleRequest(request(spoofed), async () => ({ path: "unused", commit: "unused" }), async () => ({ id: 1, login: "user" }));
  assert.equal(spoofedResponse.status, 400);
  assert.match((await spoofedResponse.json() as { error: string }).error, /Unknown manifest fields: owner/);

  const mismatched = submission("@another/foo-scoped", "Documentation");
  const mismatchedResponse = await handleRequest(request(mismatched), async () => ({ path: "unused", commit: "unused" }), async () => ({ id: 1, login: "user" }));
  assert.equal(mismatchedResponse.status, 400);
  assert.match((await mismatchedResponse.json() as { error: string }).error, /scope must match/);
});

function submission(name: string, category: string) {
  return {
    schema: "foo.publish/v1",
    manifest: {
      schema: "foo.package/v1",
      name,
      version: "1.0.0",
      description: "A test package with complete documentation.",
      category,
      tags: ["test"],
      license: "MIT",
      compatible: true,
      deprecated: "",
      platforms: ["linux"],
      updated: "2026-09-25",
      repository: `https://github.com/radiiplus/${name}`,
      revision: "0123456789abcdef0123456789abcdef01234567",
      install: `foo add ${name}`,
      dependencies: [],
    },
    documentation: Array.from({ length: 100 }, (_, index) => `Documentation line ${index + 1}.`),
    source: {
      format: "foo.source/v1",
      digest: "0".repeat(64),
      files: [{ path: "src/main.iv", content: "public constant answer is 42.\n" }],
    },
    api: {
      schema: "foo.api/v1",
      modules: [{
        name: "main",
        path: "src/main.iv",
        summary: "",
        items: [{ kind: "constant", name: "answer", declaration: "public constant answer.", documentation: "" }],
      }],
    },
  };
}

function request(body: unknown) {
  return new Request("http://localhost/functions/v1/registry/publish", {
    method: "POST",
    headers: { authorization: "Bearer token", "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function git(repository: string, ...arguments_: string[]) {
  const { stdout } = await execute("git", ["-C", repository, ...arguments_]);
  return stdout.trim();
}
