import { createHash } from "node:crypto";

const limit = 100_000;

const token = process.env.GITHUB_TOKEN;
const repository = process.env.GITHUB_REPOSITORY ?? "radiiplus/foo.registry";
const branch = process.env.GITHUB_BRANCH ?? "main";
if (process.argv[2] !== "--confirm") throw new Error("Pass --confirm to remove every non-standard package");
if (!token) throw new Error("GITHUB_TOKEN is required");
if (!/^[^/]+\/[^/]+$/.test(repository)) throw new Error("GITHUB_REPOSITORY must be owner/name");

const api = `https://api.github.com/repos/${repository}`;
const reference = await request(`/git/ref/heads/${encodeURIComponent(branch)}`, "GET");
const parent = reference.object?.sha;
if (!parent) throw new Error("Registry branch has no head commit");
const commit = await request(`/git/commits/${parent}`, "GET");
if (!commit.tree?.sha) throw new Error("Registry head has no tree");
const current = await request(`/git/trees/${commit.tree.sha}?recursive=1`, "GET");
if (current.truncated) throw new Error("Registry tree listing was truncated");

const packageRecord = /^packages\/.+\/(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?\.json$/;
const standardItems = current.tree.filter((item) => item.type === "blob" &&
  item.path?.startsWith("packages/std/") && packageRecord.test(item.path));
const removals = current.tree.filter((item) => item.type === "blob" &&
  item.path?.startsWith("packages/") && !item.path.startsWith("packages/std/"));
if (standardItems.length === 0) throw new Error("Refusing to purge a registry with no standard packages");
if (removals.length === 0) {
  console.log("No non-standard packages remain");
  process.exit(0);
}

const paths = new Map(current.tree.filter((item) => item.type === "blob").map((item) => [item.path, item]));
const manifestItem = paths.get("indexes/index.json");
if (!manifestItem) throw new Error("Registry index manifest is missing");
const manifest = JSON.parse(await content(manifestItem));
const indexed = [];
for (const shard of manifest.shards ?? []) {
  const item = paths.get(shard.path);
  if (!item) throw new Error(`Registry shard is missing: ${shard.path}`);
  for (const line of (await content(item)).split(/\r?\n/).filter((value) => value.trim())) {
    const entry = JSON.parse(line);
    if (entry.kind === "standard" && entry.name?.startsWith("std/")) indexed.push(entry);
  }
}
indexed.sort((left, right) => compare(left.category, right.category) || compare(left.name, right.name));
if (new Set(indexed.map((entry) => entry.name)).size !== indexed.length) throw new Error("Duplicate standard index entries found");
const groups = [];
for (let offset = 0; offset < indexed.length; offset += limit) groups.push(indexed.slice(offset, offset + limit));
const files = new Map();
const descriptors = [];
for (let index = 0; index < groups.length; index += 1) {
  const group = groups[index];
  const path = `indexes/index-${String(index + 1).padStart(6, "0")}.jsonl`;
  files.set(path, `${group.map((entry) => JSON.stringify(entry)).join("\n")}\n`);
  descriptors.push({
    path,
    count: group.length,
    first: { category: group[0].category, name: group[0].name },
    last: { category: group.at(-1).category, name: group.at(-1).name },
  });
}
const revision = createHash("sha256").update(JSON.stringify(indexed)).digest("hex");
files.set("indexes/index.json", `${JSON.stringify({
  schema: "foo.registry/v1",
  revision,
  count: indexed.length,
  order: ["category", "name"],
  limit,
  shards: descriptors,
}, null, 2)}\n`);

const changes = removals.map((item) => ({ path: item.path, mode: "100644", type: "blob", sha: null }));
for (const item of current.tree) {
  if (item.type === "blob" && /^indexes\/index-\d{6}\.(?:json|jsonl)$/.test(item.path ?? "") && !files.has(item.path)) {
    changes.push({ path: item.path, mode: "100644", type: "blob", sha: null });
  }
}
for (const [path, content] of files) {
  const blob = await request("/git/blobs", "POST", { content, encoding: "utf-8" });
  changes.push({ path, mode: "100644", type: "blob", sha: blob.sha });
}

const createdTree = await request("/git/trees", "POST", { base_tree: commit.tree.sha, tree: changes });
const createdCommit = await request("/git/commits", "POST", {
  message: "remove non-standard packages",
  tree: createdTree.sha,
  parents: [parent],
});
await request(`/git/refs/heads/${encodeURIComponent(branch)}`, "PATCH", { sha: createdCommit.sha, force: false });
console.log(`removed ${removals.length} package file(s); retained ${indexed.length} standard packages at ${createdCommit.sha}`);

async function content(item) {
  const blob = await request(`/git/blobs/${item.sha}`, "GET");
  if (blob.encoding !== "base64" || typeof blob.content !== "string") throw new Error(`Invalid blob: ${item.path}`);
  return Buffer.from(blob.content.replace(/\s/g, ""), "base64").toString("utf8");
}

function compare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

async function request(path, method, body) {
  const response = await fetch(`${api}${path}`, {
    method,
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      "user-agent": "foo-registry-purge",
      "x-github-api-version": "2026-03-10",
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (!response.ok) {
    const error = await response.json().catch(() => ({}));
    throw new Error(`GitHub ${method} ${path} failed: ${error.message ?? response.status}`);
  }
  return response.json();
}
