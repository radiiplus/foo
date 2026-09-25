import { execFile } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { promisify } from "node:util";

import { buildIndexes, mergeRelease, parseRegistry, parseShard, type IndexEntry } from "./serverless/supabase/functions/_shared/indexer.ts";
import type { PackageRecord } from "./serverless/supabase/functions/_shared/manifest.ts";
import { assertPublicationName, PublishError, type PublishResult } from "./serverless/supabase/functions/_shared/publisher.ts";
import { registryOwner, sameOwner, type GitHubIdentity } from "./serverless/supabase/functions/_shared/identity.ts";
import { releaseFiles } from "./serverless/supabase/functions/_shared/release.ts";

const execute = promisify(execFile);

export function createLocalPublisher(repository: string) {
  return async (record: PackageRecord): Promise<PublishResult> => {
    const { entries, shards } = await catalog(repository);
    const existing = assertPublicationName(entries, record);
    if (existing?.versions.some((version) => version.version === record.version)) throw new PublishError("Package version already exists", 409);

    const built = await buildIndexes(mergeRelease(entries, record));
    const path = `packages/${record.name}/${record.version}.json`;
    const target = join(repository, ...path.split("/"));
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, json(record));
    for (const [file, content] of releaseFiles(record)) {
      const output = join(repository, ...file.split("/"));
      await mkdir(dirname(output), { recursive: true });
      await writeFile(output, content);
    }
    for (const [file, content] of built.files) {
      const output = join(repository, ...file.split("/"));
      await mkdir(dirname(output), { recursive: true });
      await writeFile(output, content);
    }
    const retained = new Set(built.manifest.shards.map((shard) => shard.path));
    for (const shard of shards) if (!retained.has(shard)) await rm(join(repository, ...shard.split("/")), { force: true });

    await execute("git", ["-C", repository, "add", "packages", "indexes"]);
    await execute("git", ["-C", repository, "commit", "-m", `publish ${record.name}@${record.version}`]);
    const { stdout } = await execute("git", ["-C", repository, "rev-parse", "HEAD"]);
    return { path, commit: stdout.trim() };
  };
}

export function createLocalDeprecator(repository: string) {
  return async (name: string, version: string, message: string, owner: GitHubIdentity): Promise<PublishResult> => {
    const { entries, shards } = await catalog(repository);
    const entry = entries.find((candidate) => candidate.name === name);
    const selected = entry?.versions.find((candidate) => candidate.version === version);
    if (!entry || !selected) throw new PublishError(`Package version not found: ${name}@${version}`, 404);
    if (!sameOwner(entry.owner, await registryOwner(owner))) throw new PublishError("Only the original owner can deprecate this package", 403);
    const target = join(repository, ...selected.path.split("/"));
    const record = JSON.parse(await readFile(target, "utf8")) as PackageRecord;
    record.deprecated = message.trim();
    const built = await buildIndexes(mergeRelease(entries, record));
    await writeFile(target, json(record));
    for (const [file, content] of built.files) {
      const output = join(repository, ...file.split("/"));
      await mkdir(dirname(output), { recursive: true });
      await writeFile(output, content);
    }
    const retained = new Set(built.manifest.shards.map((shard) => shard.path));
    for (const shard of shards) if (!retained.has(shard)) await rm(join(repository, ...shard.split("/")), { force: true });
    await execute("git", ["-C", repository, "add", "packages", "indexes"]);
    await execute("git", ["-C", repository, "commit", "-m", `deprecate ${name}@${version}`]);
    const { stdout } = await execute("git", ["-C", repository, "rev-parse", "HEAD"]);
    return { path: selected.path, commit: stdout.trim() };
  };
}

async function catalog(repository: string): Promise<{ entries: IndexEntry[]; shards: string[] }> {
  try {
    const manifest = parseRegistry(JSON.parse(await readFile(join(repository, "indexes", "index.json"), "utf8")));
    const batches = await Promise.all(manifest.shards.map(async (shard) => parseShard(await readFile(join(repository, ...shard.path.split("/")), "utf8"))));
    return { entries: batches.flat(), shards: manifest.shards.map((shard) => shard.path) };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { entries: [], shards: [] };
    throw error;
  }
}

function json(value: unknown) {
  return `${JSON.stringify(value, null, 2)}\n`;
}
