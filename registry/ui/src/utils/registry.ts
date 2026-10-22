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

export type Declaration = {
  kind: "function" | "type" | "constant" | "value";
  name: string;
  declaration: string;
  documentation: string;
};

export type Api = {
  schema: "foo.api/v1";
  modules: Array<{ name: string; path: string; summary: string; items: Declaration[] }>;
};

export type Version = {
  version: string;
  updated: string;
  deprecated: string;
  path: string;
};

export type Summary = {
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
  versions: Version[];
};

export type Package = Omit<Summary, "path" | "versions"> & {
  install: string;
  dependencies: Dependency[];
  readme: string[];
  api: Api;
  source: { format: "foo.source/v1"; digest: string; files: Array<{ path: string; content: string }> };
};

export type Standard = Pick<Package, "kind" | "name" | "version" | "description" | "owner" | "install" | "api">;

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

type Response = {
  schema: "foo.search/v1";
  packages: Summary[];
  total: number;
  query: string;
  offset: number;
  limit: number;
  next: number | null;
  facets: { categories: Category[]; tags: Tag[] };
};

type Manifest = {
  schema: "foo.registry/v1";
  revision: string;
  count: number;
  shards: Array<{ path: string; count: number }>;
};

type Inventory = {
  schema: "foo.standard-catalog/v1";
  revision: string;
  count: number;
  entries: Summary[];
  packages: Package[];
};
type Catalog = { manifest: Manifest; entries: Summary[]; standard: Map<string, Package>; revision: string };

const source = (import.meta.env.VITE_REGISTRY_URL ?? (import.meta.env.DEV
  ? "/registry-data"
  : "https://raw.githubusercontent.com/radiiplus/foo.registry/main")).replace(/\/$/, "");
const upstream = (import.meta.env.VITE_FOO_SOURCE_URL ?? (import.meta.env.DEV
  ? "/foo-data"
  : "https://raw.githubusercontent.com/radiiplus/foo/main")).replace(/\/$/, "");
const lifetime = 60_000;
let cache: { expires: number; value: Promise<Catalog> } | undefined;

export async function health(signal?: AbortSignal): Promise<Health> {
  const catalog = await load(signal);
  return { service: "foo-registry-git", status: "ok", version: catalog.revision };
}

export async function packages(query: Query = {}, signal?: AbortSignal) {
  const catalog = await load(signal);
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
  const response: Response = {
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
  return { categories: facets((await load(signal)).entries).categories };
}

export async function tags(signal?: AbortSignal) {
  return { tags: facets((await load(signal)).entries).tags };
}

export async function item(name: string, signal?: AbortSignal, version?: string) {
  const catalog = await load(signal);
  const entry = catalog.entries.find((candidate) => candidate.name === name);
  if (!entry) throw new Error(`Package not found: ${name}`);
  const revision = version || entry.version;
  const selected = entry.versions.find((candidate) => candidate.version === revision);
  if (!selected) throw new Error(`Package version not found: ${name}@${revision}`);
  const record = entry.kind === "standard" ? catalog.standard.get(name) :
    await json<Package>(selected.path, catalog.manifest.revision, signal);
  if (!record) throw new Error(`Standard module not found: ${name}`);
  if (record.name !== name || record.version !== revision) throw new Error(`Registry package identity mismatch: ${name}@${revision}`);
  const versions = entry.versions;
  const summary = normalize({ ...entry, ...record, path: selected.path, versions, exports: entry.exports });
  const product: Package = {
    ...record,
    ...summary,
    dependencies: Array.isArray(record.dependencies) ? record.dependencies : [],
    readme: Array.isArray(record.readme) ? record.readme : [],
    api: record.api ?? { schema: "foo.api/v1", modules: [] },
    source: record.source ?? { format: "foo.source/v1", digest: "", files: [] },
  };
  return { package: product, versions };
}

export async function standards(signal?: AbortSignal) {
  const catalog = await load(signal);
  return [...catalog.standard.values()].sort((left, right) => compare(left.name, right.name))
    .map(({ kind, name, version, description, owner, install, api }): Standard =>
      ({ kind, name, version, description, owner, install, api }));
}

export function index() {
  return `${upstream}/registry/standard.json`;
}

async function load(signal?: AbortSignal): Promise<Catalog> {
  abort(signal);
  if (!cache || cache.expires <= Date.now()) {
    const value = read();
    cache = { expires: Date.now() + lifetime, value };
    void value.catch(() => {
      if (cache?.value === value) cache = undefined;
    });
  }
  const catalog = await cache.value;
  abort(signal);
  return catalog;
}

async function read(): Promise<Catalog> {
  const [manifest, standard] = await Promise.all([
    json<Manifest>("indexes/index.json"),
    builtin(),
  ]);
  if (manifest.schema !== "foo.registry/v1" || !Array.isArray(manifest.shards)) throw new Error("Invalid registry manifest");
  const batches = await Promise.all(manifest.shards.map(async (shard) => {
    if (!/^indexes\/index-\d{6}\.jsonl$/.test(shard.path)) throw new Error(`Invalid registry shard path: ${shard.path}`);
    const text = await plain(shard.path, manifest.revision);
    const entries = text.split(/\r?\n/).filter((line) => line.trim()).map((line) => normalize(JSON.parse(line) as Summary));
    if (entries.length !== shard.count) throw new Error(`Registry shard count mismatch: ${shard.path}`);
    return entries;
  }));
  const published = batches.flat();
  if (published.length !== manifest.count) throw new Error("Registry package count mismatch");
  const entries = [...published.filter((entry) => entry.kind !== "standard"), ...standard.entries.map(normalize)];
  if (new Set(entries.map((entry) => entry.name)).size !== entries.length) throw new Error("Duplicate registry package name");
  return { manifest, entries, standard: new Map(standard.packages.map((record) => [record.name, record])),
    revision: `${manifest.revision}:${standard.revision}` };
}

async function builtin(): Promise<Inventory> {
  const response = await fetch(`${upstream}/registry/standard.json`, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error("FOO standard catalog unavailable");
  const catalog = await response.json() as Inventory;
  if (catalog.schema !== "foo.standard-catalog/v1" || !Array.isArray(catalog.entries) ||
      !Array.isArray(catalog.packages) || catalog.count !== catalog.entries.length ||
      catalog.count !== catalog.packages.length || catalog.entries.some((entry, index) =>
        entry.kind !== "standard" || entry.name !== catalog.packages[index]?.name ||
        entry.version !== catalog.packages[index]?.version)) {
    throw new Error("Invalid FOO standard catalog");
  }
  return catalog;
}

function normalize(item: Summary): Summary {
  return {
    ...item,
    kind: item.kind === "standard" ? "standard" : "package",
    tags: Array.isArray(item.tags) ? item.tags : [],
    platforms: Array.isArray(item.platforms) ? item.platforms : [],
    exports: Array.isArray(item.exports) ? item.exports : [],
    versions: Array.isArray(item.versions) ? item.versions : [],
  };
}

function facets(entries: Summary[]) {
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
  if (sort === "name") return (left: Summary, right: Summary) => compare(left.name, right.name);
  if (sort === "recent") return (left: Summary, right: Summary) => compare(right.updated, left.updated) || compare(left.name, right.name);
  if (sort === "relevance") return (left: Summary, right: Summary) => relevance(left, query) - relevance(right, query) || compare(left.name, right.name);
  return (left: Summary, right: Summary) => compare(left.category, right.category) || compare(left.name, right.name);
}

function relevance(entry: Summary, query: string) {
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

async function json<T>(path: string, revision = "", signal?: AbortSignal): Promise<T> {
  const text = await plain(path, revision, signal);
  try {
    return JSON.parse(text) as T;
  } catch {
    throw new Error(`Registry data is not valid JSON: ${path}`);
  }
}

async function plain(path: string, revision = "", signal?: AbortSignal): Promise<string> {
  if (!safe(path)) throw new Error(`Unsafe registry path: ${path}`);
  const suffix = revision ? `?v=${encodeURIComponent(revision)}` : "";
  const response = await fetch(`${source}/${path}${suffix}`, { signal, headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(response.status === 404 ? `Registry content not found: ${path}` : `Registry content unavailable: ${path}`);
  return response.text();
}

function safe(path: string) {
  return (path.startsWith("indexes/") || path.startsWith("packages/")) &&
    !path.startsWith("/") && path.split("/").every((part) => part && part !== "." && part !== "..");
}

function abort(signal?: AbortSignal) {
  if (signal?.aborted) throw new DOMException("The operation was aborted", "AbortError");
}

function compare(left: string, right: string) {
  return left < right ? -1 : left > right ? 1 : 0;
}
