import assert from "node:assert/strict";
import { after, before, test } from "node:test";

import { handleRequest } from "../serverless/supabase/functions/_shared/handler.ts";
import { createServer } from "../server.ts";

process.env.OWNERSHIP_SECRET = "test-ownership-secret-with-at-least-32-characters";

const server = createServer();
let baseUrl = "";

before(async () => {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      const address = server.address();
      if (address === null || typeof address === "string") return reject(new Error("The test server did not bind to a TCP port"));
      baseUrl = `http://127.0.0.1:${address.port}`;
      resolve();
    });
  });
});

after(async () => {
  await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
});

test("serves the publication health endpoint", async () => {
  const response = await fetch(`${baseUrl}/functions/v1/registry/health`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { service: "foo", status: "ok", version: "v1" });
});

test("serves searchable Git-backed discovery endpoints", async () => {
  const search = await json(`${baseUrl}/functions/v1/registry/search?q=websocket`);
  assert.equal(search.schema, "foo.search/v1");
  assert.equal(search.total, 1);
  assert.equal(search.packages[0]?.name, "foo-http");
  assert.ok(search.packages[0]?.description);
  assert.ok(search.facets.categories.some((category: { name: string }) => category.name === "networking"));

  const category = await json(`${baseUrl}/functions/v1/registry/category/${encodeURIComponent("developer tools")}`);
  assert.deepEqual(category.packages.map((entry: { name: string }) => entry.name), ["foo-args", "foo-test"]);
  const tag = await json(`${baseUrl}/functions/v1/registry/tag/http`);
  assert.deepEqual(tag.packages.map((entry: { name: string }) => entry.name), ["foo-http", "std/http"]);

  const detail = await json(`${baseUrl}/functions/v1/registry/package/foo-http?version=1.4.2`);
  assert.equal(detail.schema, "foo.package-response/v1");
  assert.equal(detail.package.install, "foo add foo-http");
  assert.ok(detail.package.readme.length > 0);
  assert.equal(detail.package.api.schema, "foo.api/v1");
  assert.ok(detail.package.api.modules[0]?.items.length > 0);

  const resolution = await json(`${baseUrl}/functions/v1/registry/resolve/foo-http?version=1.4.2`);
  assert.equal(resolution.schema, "foo.resolution/v1");
  assert.deepEqual(resolution.packages.map((entry: { name: string }) => entry.name), ["foo-http", "foo-json"]);
});

test("rejects unknown discovery routes", async () => {
  const response = await fetch(`${baseUrl}/functions/v1/registry/packages`);
  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: "Not found" });
});

async function json(url: string) {
  const response = await fetch(url);
  assert.equal(response.status, 200);
  return response.json() as Promise<any>;
}

test("requires the authenticated stable GitHub id for publication", async () => {
  const response = await handleRequest(new Request("http://localhost/functions/v1/registry/publish", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(await submission()),
  }), async () => ({ path: "unused", commit: "unused" }));
  assert.equal(response.status, 401);
});

test("publishes a validated package through the repository writer", async () => {
  let published = "";
  const response = await handleRequest(new Request("http://localhost/functions/v1/registry/publish", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: "Bearer test" },
    body: JSON.stringify(await submission()),
  }), async (entry) => {
    published = `${entry.name}@${entry.version}`;
    return { path: `packages/${entry.name}/${entry.version}.json`, commit: "abc123" };
  }, async () => ({ id: 152736140, login: "radiiplus" }));
  assert.equal(response.status, 201);
  assert.equal(published, "foo-http@1.4.2");
  assert.deepEqual(await response.json(), {
    package: "foo-http",
    version: "1.4.2",
    owner: "radiiplus",
    path: "packages/foo-http/1.4.2.json",
    commit: "abc123",
  });
});

async function submission() {
  const response = await fetch(`${baseUrl}/functions/v1/registry/package/foo-http?version=1.4.2`);
  const detail = await response.json() as { package: Record<string, unknown> };
  const { owner: _owner, readme: _readme, source, api, kind: _kind, ...manifest } = detail.package;
  return {
    schema: "foo.publish/v1",
    manifest,
    documentation: Array.from({ length: 100 }, (_, index) => `Documentation line ${index + 1}.`),
    source,
    api,
  };
}
