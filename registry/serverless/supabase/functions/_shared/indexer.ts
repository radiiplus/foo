import type { PackageRecord } from "./manifest.ts";

export const shardLimit = 100_000;

export type VersionSummary = {
  version: string;
  updated: string;
  deprecated: string;
  path: string;
};

export type IndexEntry = Omit<PackageRecord, "schema" | "install" | "dependencies" | "readme" | "source" | "api"> & {
  schema: "foo.entry/v1";
  exports: string[];
  path: string;
  versions: VersionSummary[];
};

export type RegistryManifest = {
  schema: "foo.registry/v1";
  revision: string;
  count: number;
  order: ["category", "name"];
  limit: 100000;
  shards: Array<{
    path: string;
    count: number;
    first: { category: string; name: string };
    last: { category: string; name: string };
  }>;
};

export type IndexBuild = {
  entries: IndexEntry[];
  manifest: RegistryManifest;
  files: Map<string, string>;
};

export function mergeRelease(current: IndexEntry[], release: PackageRecord) {
  const existing = current.find((entry) => entry.name === release.name);
  const version: VersionSummary = {
    version: release.version,
    updated: release.updated,
    deprecated: release.deprecated,
    path: `packages/${release.name}/${release.version}.json`,
  };
  const versions = [...(existing?.versions ?? []).filter((item) => item.version !== release.version), version]
    .sort((left, right) => compareVersions(right.version, left.version));
  const latestVersion = versions.find((item) => !item.version.includes("-")) ?? versions[0];
  const latestIsRelease = latestVersion.version === release.version;
  const entry: IndexEntry = latestIsRelease || !existing ? fromRelease(release, versions) : { ...existing, versions };
  return [...current.filter((item) => item.name !== release.name), entry]
    .sort((left, right) => compare(left.category, right.category) || compare(left.name, right.name));
}

export async function buildIndexes(entries: IndexEntry[], size = shardLimit): Promise<IndexBuild> {
  if (!Number.isSafeInteger(size) || size < 1 || size > shardLimit) throw new RangeError(`Shard size must be between 1 and ${shardLimit}`);
  const sorted = [...entries].sort((left, right) => compare(left.category, right.category) || compare(left.name, right.name));
  const files = new Map<string, string>();
  const descriptors: RegistryManifest["shards"] = [];
  for (let offset = 0; offset < sorted.length; offset += size) {
    const group = sorted.slice(offset, offset + size);
    const filename = `index-${String(descriptors.length + 1).padStart(6, "0")}.jsonl`;
    const path = `indexes/${filename}`;
    files.set(path, `${group.map((entry) => JSON.stringify(entry)).join("\n")}\n`);
    descriptors.push({
      path,
      count: group.length,
      first: { category: group[0].category, name: group[0].name },
      last: { category: group.at(-1)!.category, name: group.at(-1)!.name },
    });
  }
  const revision = await sha256(JSON.stringify(sorted));
  const manifest: RegistryManifest = {
    schema: "foo.registry/v1",
    revision,
    count: sorted.length,
    order: ["category", "name"],
    limit: shardLimit,
    shards: descriptors,
  };
  files.set("indexes/index.json", json(manifest));
  return { entries: sorted, manifest, files };
}

export function parseRegistry(value: unknown): RegistryManifest {
  if (!object(value) || value.schema !== "foo.registry/v1" || !Array.isArray(value.shards)) throw new TypeError("Invalid registry manifest");
  return value as unknown as RegistryManifest;
}

export function parseShard(value: string): IndexEntry[] {
  const lines = value.split(/\r?\n/).filter((line) => line.trim().length > 0);
  return lines.map((line, index) => {
    let entry: unknown;
    try {
      entry = JSON.parse(line);
    } catch {
      throw new TypeError(`Invalid JSONL at line ${index + 1}`);
    }
    if (!object(entry) || entry.schema !== "foo.entry/v1" || typeof entry.name !== "string" ||
        typeof entry.category !== "string" || !Array.isArray(entry.versions)) {
      throw new TypeError(`Invalid registry entry at line ${index + 1}`);
    }
    return entry as unknown as IndexEntry;
  });
}

function fromRelease(release: PackageRecord, versions: VersionSummary[]): IndexEntry {
  return {
    schema: "foo.entry/v1",
    kind: release.kind,
    name: release.name,
    version: release.version,
    description: release.description,
    category: release.category,
    tags: release.tags,
    license: release.license,
    compatible: release.compatible,
    deprecated: release.deprecated,
    platforms: release.platforms,
    updated: release.updated,
    owner: release.owner,
    repository: release.repository,
    revision: release.revision,
    exports: [...new Set(release.api.modules.flatMap((module) => module.items.map((item) => item.name)))].sort(compare),
    path: `packages/${release.name}/${release.version}.json`,
    versions,
  };
}

function compareVersions(left: string, right: string) {
  const pattern = /^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/;
  const a = pattern.exec(left)!;
  const b = pattern.exec(right)!;
  for (let index = 1; index <= 3; index += 1) {
    const difference = Number(a[index]) - Number(b[index]);
    if (difference) return difference;
  }
  if (!a[4] && b[4]) return 1;
  if (a[4] && !b[4]) return -1;
  return compare(a[4] ?? "", b[4] ?? "");
}

function compare(left: string, right: string) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function json(value: unknown) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

async function sha256(value: string) {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
