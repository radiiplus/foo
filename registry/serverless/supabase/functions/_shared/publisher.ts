import { setting } from "./environment.ts";
import { buildIndexes, mergeRelease, parseRegistry, parseShard, type IndexEntry, type RegistryManifest } from "./indexer.ts";
import type { PackageRecord } from "./manifest.ts";
import { registryOwner, sameOwner, type GitHubIdentity } from "./identity.ts";
import { releaseFiles } from "./release.ts";

export type PublishResult = {
  path: string;
  commit: string;
};

export class PublishError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export async function publishPackage(record: PackageRecord): Promise<PublishResult> {
  const token = setting("GITHUB_TOKEN");
  const repository = setting("GITHUB_REPOSITORY") ?? "radiiplus/foo.registry";
  const branch = setting("GITHUB_BRANCH") ?? "main";
  if (!token || !/^[^/]+\/[^/]+$/.test(repository)) throw new PublishError("GitHub publication is not configured", 503);
  const github = new GitHub(repository, token);
  const reference = await github.get(`/git/ref/heads/${encodeURIComponent(branch)}`) as { object?: { sha?: string } };
  const parent = reference.object?.sha;
  if (!parent) throw new PublishError("Registry branch has no head commit", 502);
  const commit = await github.get(`/git/commits/${parent}`) as { tree?: { sha?: string } };
  const baseTree = commit.tree?.sha;
  if (!baseTree) throw new PublishError("Registry head has no tree", 502);

  const { entries, manifest: previous } = await catalog(github, parent);
  const existing = assertPublicationName(entries, record);
  if (existing?.versions.some((version) => version.version === record.version)) throw new PublishError("Package version already exists", 409);

  const built = await buildIndexes(mergeRelease(entries, record));
  const path = `packages/${record.name}/${record.version}.json`;
  const contents = new Map(built.files);
  contents.set(path, json(record));
  for (const [file, content] of releaseFiles(record)) contents.set(file, content);
  const tree = await Promise.all([...contents].map(async ([file, content]) => ({
    path: file,
    mode: "100644",
    type: "blob",
    sha: ((await github.post("/git/blobs", { content, encoding: "utf-8" })) as { sha: string }).sha,
  })));
  const retained = new Set(built.manifest.shards.map((shard) => shard.path));
  for (const shard of previous?.shards ?? []) {
    if (!retained.has(shard.path)) tree.push({ path: shard.path, mode: "100644", type: "blob", sha: null as unknown as string });
  }

  const createdTree = await github.post("/git/trees", { base_tree: baseTree, tree }) as { sha?: string };
  if (!createdTree.sha) throw new PublishError("GitHub returned no tree", 502);
  const createdCommit = await github.post("/git/commits", {
    message: `publish ${record.name}@${record.version}`,
    tree: createdTree.sha,
    parents: [parent],
  }) as { sha?: string };
  if (!createdCommit.sha) throw new PublishError("GitHub returned no commit", 502);
  await github.patch(`/git/refs/heads/${encodeURIComponent(branch)}`, { sha: createdCommit.sha, force: false }, true);
  return { path, commit: createdCommit.sha };
}

export async function deprecatePackage(name: string, version: string, message: string, owner: GitHubIdentity): Promise<PublishResult> {
  if (!message.trim()) throw new PublishError("Deprecation message is required", 400);
  const token = setting("GITHUB_TOKEN");
  const repository = setting("GITHUB_REPOSITORY") ?? "radiiplus/foo.registry";
  const branch = setting("GITHUB_BRANCH") ?? "main";
  if (!token || !/^[^/]+\/[^/]+$/.test(repository)) throw new PublishError("GitHub publication is not configured", 503);
  const github = new GitHub(repository, token);
  const reference = await github.get(`/git/ref/heads/${encodeURIComponent(branch)}`) as { object?: { sha?: string } };
  const parent = reference.object?.sha;
  if (!parent) throw new PublishError("Registry branch has no head commit", 502);
  const commit = await github.get(`/git/commits/${parent}`) as { tree?: { sha?: string } };
  if (!commit.tree?.sha) throw new PublishError("Registry head has no tree", 502);
  const { entries, manifest: previous } = await catalog(github, parent);
  const signedOwner = await registryOwner(owner);
  const entry = entries.find((candidate) => candidate.name === name);
  const selected = entry?.versions.find((candidate) => candidate.version === version);
  if (!entry || !selected) throw new PublishError(`Package version not found: ${name}@${version}`, 404);
  if (!sameOwner(entry.owner, signedOwner)) throw new PublishError("Only the original owner can deprecate this package", 403);
  const record = JSON.parse(await github.content(selected.path, parent) as string) as PackageRecord;
  if (!sameOwner(record.owner, signedOwner)) throw new PublishError("Package ownership mismatch", 403);
  record.deprecated = message.trim();
  const built = await buildIndexes(mergeRelease(entries, record));
  const contents = new Map(built.files);
  contents.set(selected.path, json(record));
  const tree = await Promise.all([...contents].map(async ([file, content]) => ({
    path: file, mode: "100644", type: "blob",
    sha: ((await github.post("/git/blobs", { content, encoding: "utf-8" })) as { sha: string }).sha,
  })));
  const retained = new Set(built.manifest.shards.map((shard) => shard.path));
  for (const shard of previous?.shards ?? []) {
    if (!retained.has(shard.path)) tree.push({ path: shard.path, mode: "100644", type: "blob", sha: null as unknown as string });
  }
  const createdTree = await github.post("/git/trees", { base_tree: commit.tree.sha, tree }) as { sha?: string };
  if (!createdTree.sha) throw new PublishError("GitHub returned no tree", 502);
  const createdCommit = await github.post("/git/commits", {
    message: `deprecate ${name}@${version}`, tree: createdTree.sha, parents: [parent],
  }) as { sha?: string };
  if (!createdCommit.sha) throw new PublishError("GitHub returned no commit", 502);
  await github.patch(`/git/refs/heads/${encodeURIComponent(branch)}`, { sha: createdCommit.sha, force: false }, true);
  return { path: selected.path, commit: createdCommit.sha };
}

export function assertPublicationName(entries: IndexEntry[], record: PackageRecord) {
  const existing = entries.find((entry) => entry.name === record.name);
  const basename = leaf(record.name);
  const collision = entries.find((entry) => leaf(entry.name) === basename && !sameOwner(entry.owner, record.owner));
  if (existing && !sameOwner(existing.owner, record.owner)) {
    throw new PublishError(`Package name is owned by another publisher; use @${record.owner.login.toLowerCase()}/${basename}`, 409);
  }
  if (!record.name.startsWith("@") && !existing && collision) {
    throw new PublishError(`Package name already exists; publish as @${record.owner.login.toLowerCase()}/${basename}`, 409);
  }
  return existing;
}

function leaf(name: string) {
  return name.slice(name.lastIndexOf("/") + 1);
}

async function catalog(github: GitHub, reference: string): Promise<{ entries: IndexEntry[]; manifest?: RegistryManifest }> {
  const value = await github.content("indexes/index.json", reference, true);
  if (value === undefined) return { entries: [] };
  const manifest = parseRegistry(JSON.parse(value));
  const batches = await Promise.all(manifest.shards.map(async (shard) => parseShard(await github.content(shard.path, reference) as string)));
  return { entries: batches.flat(), manifest };
}

class GitHub {
  private readonly base: string;
  private readonly headers: Record<string, string>;

  constructor(repository: string, token: string) {
    this.base = `https://api.github.com/repos/${repository}`;
    this.headers = {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "content-type": "application/json",
      "user-agent": "foo-registry",
      "x-github-api-version": "2026-03-10",
    };
  }

  get(path: string) {
    return this.request(path, "GET");
  }

  post(path: string, body: unknown) {
    return this.request(path, "POST", body);
  }

  patch(path: string, body: unknown, conflict = false) {
    return this.request(path, "PATCH", body, conflict);
  }

  async content(path: string, reference: string, optional = false) {
    const response = await fetch(`${this.base}/contents/${path}?ref=${encodeURIComponent(reference)}`, { headers: this.headers });
    if (optional && response.status === 404) return undefined;
    if (!response.ok) throw await failure(response, "GitHub content read failed");
    const value = await response.json() as { content?: string; encoding?: string };
    if (!value.content || value.encoding !== "base64") throw new PublishError("GitHub returned invalid file content", 502);
    return decode(value.content.replace(/\s/g, ""));
  }

  private async request(path: string, method: string, body?: unknown, conflict = false) {
    const response = await fetch(`${this.base}${path}`, {
      method,
      headers: this.headers,
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    if (!response.ok) {
      if (conflict && (response.status === 409 || response.status === 422)) throw new PublishError("Registry changed during publication; retry", 409);
      throw await failure(response, `GitHub ${method} failed`);
    }
    return response.json() as Promise<unknown>;
  }
}

async function failure(response: Response, prefix: string) {
  const body = await response.json().catch(() => ({})) as { message?: string };
  return new PublishError(`${prefix}: ${body.message ?? response.status}`, response.status === 404 ? 404 : 502);
}

function decode(value: string) {
  const binary = atob(value);
  return new TextDecoder().decode(Uint8Array.from(binary, (character) => character.charCodeAt(0)));
}

function json(value: unknown) {
  return `${JSON.stringify(value, null, 2)}\n`;
}
