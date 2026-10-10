export type Health = {
  service: string;
  status: "ok";
  version: string;
};

export type Dependency = {
  name: string;
  version: string;
  kind?: "runtime" | "dev" | "optional" | "platform";
  platforms?: string[];
};

export type PublicApiItem = {
  kind: "function" | "type" | "constant" | "value";
  name: string;
  declaration: string;
  documentation: string;
};

export type PublicApi = {
  schema: "foo.api/v1";
  modules: Array<{ name: string; path: string; summary: string; items: PublicApiItem[] }>;
};

export type VersionSummary = {
  version: string;
  updated: string;
  deprecated: string;
  path: string;
};

export type PackageSummary = {
  kind: "package" | "standard";
  name: string;
  version: string;
  description: string;
  icon?: string;
  category: string;
  tags: string[];
  license: string;
  compatible: boolean;
  deprecated: string;
  platforms: string[];
  updated: string;
  owner: { signature: string; login: string };
  repository: string;
  revision: string;
  exports: string[];
  path: string;
  versions: VersionSummary[];
};

export type Package = Omit<PackageSummary, "path" | "versions"> & {
  install: string;
  dependencies: Dependency[];
  readme: string[];
  api: PublicApi;
  source: { format: "foo.source/v1"; digest: string; files: Array<{ path: string; content: string }> };
};

export type StandardPackage = Pick<Package, "kind" | "name" | "version" | "description" | "owner" | "install" | "api">;

export type Category = { name: string; count: number };
export type Tag = { name: string; count: number };

export type Query = {
  query?: string;
  category?: string;
  tag?: string;
  kind?: "package" | "standard";
  sort?: "category" | "recent" | "name";
  offset?: number;
  limit?: number;
};

type SearchResponse = {
  schema: "foo.search/v1";
  packages: PackageSummary[];
  total: number;
  query: string;
  offset: number;
  limit: number;
  next: number | null;
  facets: { categories: Category[]; tags: Tag[] };
};

type RegistryManifest = {
  schema: "foo.registry/v1";
  revision: string;
  count: number;
  shards: Array<{ path: string; count: number }>;
};

type StandardCatalog = {
  schema: "foo.standard-catalog/v1";
  revision: string;
  count: number;
  entries: PackageSummary[];
  packages: Package[];
};
type Catalog = { manifest: RegistryManifest; entries: PackageSummary[]; standard: Map<string, Package>; revision: string };

const source = (import.meta.env.VITE_REGISTRY_URL ?? (import.meta.env.DEV
  ? "/registry-data"
  : "https://raw.githubusercontent.com/radiiplus/foo.registry/main")).replace(/\/$/, "");
const fooSource = (import.meta.env.VITE_FOO_SOURCE_URL ?? (import.meta.env.DEV
  ? "/foo-data"
  : "https://raw.githubusercontent.com/radiiplus/foo/main")).replace(/\/$/, "");
const catalogLifetime = 60_000;
let catalogCache: { expires: number; value: Promise<Catalog> } | undefined;

export async function health(signal?: AbortSignal): Promise<Health> {
  const catalog = await loadCatalog(signal);
  return { service: "foo-registry-git", status: "ok", version: catalog.revision };
}

export async function packages(query: Query = {}, signal?: AbortSignal) {
  const catalog = await loadCatalog(signal);
  const needle = query.query?.trim().toLowerCase() ?? "";
  const category = query.category?.trim().toLowerCase() ?? "";
  const tag = query.tag?.trim().toLowerCase() ?? "";
  const offset = integer(query.offset, 0, 0, Number.MAX_SAFE_INTEGER);
  const limit = integer(query.limit, 24, 1, 100);
  const matches = catalog.entries.filter((entry) => {
    const searchable = [entry.name, entry.description, entry.category, ...entry.tags, ...entry.exports].join(" ").toLowerCase();
    return (!needle || searchable.includes(needle)) && (!category || entry.category === category) &&
      (!tag || entry.tags.includes(tag)) && (!query.kind || entry.kind === query.kind);
  });
  matches.sort(sorter(query.sort ?? (needle ? "relevance" : "category"), needle));
  const selected = matches.slice(offset, offset + limit);
  const response: SearchResponse = {
    schema: "foo.search/v1",
    packages: selected,
    total: matches.length,
    query: needle,
    offset,
    limit,
    next: offset + selected.length < matches.length ? offset + selected.length : null,
    facets: facets(catalog.entries),
  };
  return response;
}

export async function categories(signal?: AbortSignal) {
  return { categories: facets((await loadCatalog(signal)).entries).categories };
}

export async function tags(signal?: AbortSignal) {
  return { tags: facets((await loadCatalog(signal)).entries).tags };
}

export async function item(name: string, signal?: AbortSignal, version?: string) {
  const catalog = await loadCatalog(signal);
  const entry = catalog.entries.find((candidate) => candidate.name === name);
  if (!entry) throw new Error(`Package not found: ${name}`);
  const selectedVersion = version || entry.version;
  const selected = entry.versions.find((candidate) => candidate.version === selectedVersion);
  if (!selected) throw new Error(`Package version not found: ${name}@${selectedVersion}`);
  const record = entry.kind === "standard" ? catalog.standard.get(name) :
    await fetchRegistryJson<Package>(selected.path, catalog.manifest.revision, signal);
  if (!record) throw new Error(`Standard module not found: ${name}`);
  if (record.name !== name || record.version !== selectedVersion) throw new Error(`Registry package identity mismatch: ${name}@${selectedVersion}`);
  const versions = entry.versions;
  const summary = normalizeSummary({ ...entry, ...record, path: selected.path, versions, exports: entry.exports });
  const packageItem: Package = {
    ...record,
    ...summary,
    dependencies: Array.isArray(record.dependencies) ? record.dependencies : [],
    readme: Array.isArray(record.readme) ? record.readme : [],
    api: record.api ?? { schema: "foo.api/v1", modules: [] },
    source: record.source ?? { format: "foo.source/v1", digest: "", files: [] },
  };
  return { package: packageItem, versions };
}

export async function standards(signal?: AbortSignal) {
  const catalog = await loadCatalog(signal);
  return [...catalog.standard.values()].sort((left, right) => compare(left.name, right.name))
    .map(({ kind, name, version, description, owner, install, api }): StandardPackage =>
      ({ kind, name, version, description, owner, install, api }));
}

export function standardIndex() {
  return `${fooSource}/registry/standard.json`;
}

async function loadCatalog(signal?: AbortSignal): Promise<Catalog> {
  throwIfAborted(signal);
  if (!catalogCache || catalogCache.expires <= Date.now()) {
    const value = readCatalog();
    catalogCache = { expires: Date.now() + catalogLifetime, value };
    void value.catch(() => {
      if (catalogCache?.value === value) catalogCache = undefined;
    });
  }
  const catalog = await catalogCache.value;
  throwIfAborted(signal);
  return catalog;
}

async function readCatalog(): Promise<Catalog> {
  const [manifest, standard] = await Promise.all([
    fetchRegistryJson<RegistryManifest>("indexes/index.json"),
    fetchFooCatalog(),
  ]);
  if (manifest.schema !== "foo.registry/v1" || !Array.isArray(manifest.shards)) throw new Error("Invalid registry manifest");
  const batches = await Promise.all(manifest.shards.map(async (shard) => {
    if (!/^indexes\/index-\d{6}\.jsonl$/.test(shard.path)) throw new Error(`Invalid registry shard path: ${shard.path}`);
    const text = await fetchRegistryText(shard.path, manifest.revision);
    const entries = text.split(/\r?\n/).filter((line) => line.trim()).map((line) => normalizeSummary(JSON.parse(line) as PackageSummary));
    if (entries.length !== shard.count) throw new Error(`Registry shard count mismatch: ${shard.path}`);
    return entries;
  }));
  const published = batches.flat();
  if (published.length !== manifest.count) throw new Error("Registry package count mismatch");
  const entries = [...published.filter((entry) => entry.kind !== "standard"), ...standard.entries.map(normalizeSummary)];
  if (new Set(entries.map((entry) => entry.name)).size !== entries.length) throw new Error("Duplicate registry package name");
  return { manifest, entries, standard: new Map(standard.packages.map((record) => [record.name, record])),
    revision: `${manifest.revision}:${standard.revision}` };
}

async function fetchFooCatalog(): Promise<StandardCatalog> {
  const response = await fetch(`${fooSource}/registry/standard.json`, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error("FOO standard catalog unavailable");
  const catalog = await response.json() as StandardCatalog;
  if (catalog.schema !== "foo.standard-catalog/v1" || !Array.isArray(catalog.entries) ||
      !Array.isArray(catalog.packages) || catalog.count !== catalog.entries.length ||
      catalog.count !== catalog.packages.length || catalog.entries.some((entry, index) =>
        entry.kind !== "standard" || entry.name !== catalog.packages[index]?.name ||
        entry.version !== catalog.packages[index]?.version)) {
    throw new Error("Invalid FOO standard catalog");
  }
  return catalog;
}

function normalizeSummary(item: PackageSummary): PackageSummary {
  return {
    ...item,
    kind: item.kind === "standard" ? "standard" : "package",
    tags: Array.isArray(item.tags) ? item.tags : [],
    platforms: Array.isArray(item.platforms) ? item.platforms : [],
    exports: Array.isArray(item.exports) ? item.exports : [],
    versions: Array.isArray(item.versions) ? item.versions : [],
  };
}

function facets(entries: PackageSummary[]) {
  const categories = new Map<string, number>();
  const tags = new Map<string, number>();
  for (const entry of entries) {
    categories.set(entry.category, (categories.get(entry.category) ?? 0) + 1);
    for (const tag of entry.tags) tags.set(tag, (tags.get(tag) ?? 0) + 1);
  }
  return {
    categories: [...categories].map(([name, count]) => ({ name, count })).sort((left, right) => compare(left.name, right.name)),
    tags: [...tags].map(([name, count]) => ({ name, count })).sort((left, right) => right.count - left.count || compare(left.name, right.name)),
  };
}

function sorter(sort: Query["sort"] | "relevance", query: string) {
  if (sort === "name") return (left: PackageSummary, right: PackageSummary) => compare(left.name, right.name);
  if (sort === "recent") return (left: PackageSummary, right: PackageSummary) => compare(right.updated, left.updated) || compare(left.name, right.name);
  if (sort === "relevance") return (left: PackageSummary, right: PackageSummary) => relevance(left, query) - relevance(right, query) || compare(left.name, right.name);
  return (left: PackageSummary, right: PackageSummary) => compare(left.category, right.category) || compare(left.name, right.name);
}

function relevance(entry: PackageSummary, query: string) {
  if (entry.name === query) return 0;
  if (entry.name.startsWith(query)) return 1;
  if (entry.name.includes(query)) return 2;
  if (entry.exports.some((name) => name.toLowerCase() === query)) return 3;
  if (entry.tags.includes(query)) return 4;
  if (entry.category.includes(query)) return 5;
  return 6;
}

function integer(value: number | undefined, fallback: number, minimum: number, maximum: number) {
  const selected = value ?? fallback;
  if (!Number.isSafeInteger(selected) || selected < minimum || selected > maximum) throw new Error("Invalid registry pagination");
  return selected;
}

async function fetchRegistryJson<T>(path: string, revision = "", signal?: AbortSignal): Promise<T> {
  const text = await fetchRegistryText(path, revision, signal);
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(`Registry data is not valid JSON: ${path}`);
  }
}

async function fetchRegistryText(path: string, revision = "", signal?: AbortSignal): Promise<string> {
  if (!safePath(path)) throw new Error(`Unsafe registry path: ${path}`);
  const suffix = revision ? `?v=${encodeURIComponent(revision)}` : "";
  const response = await fetch(`${source}/${path}${suffix}`, { signal, headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(response.status === 404 ? `Registry content not found: ${path}` : `Registry content unavailable: ${path}`);
  return response.text();
}

function safePath(path: string) {
  return (path.startsWith("indexes/") || path.startsWith("packages/")) &&
    !path.startsWith("/") && path.split("/").every((part) => part && part !== "." && part !== "..");
}

function throwIfAborted(signal?: AbortSignal) {
  if (signal?.aborted) throw new DOMException("The operation was aborted", "AbortError");
}

function compare(left: string, right: string) {
  return left < right ? -1 : left > right ? 1 : 0;
}
