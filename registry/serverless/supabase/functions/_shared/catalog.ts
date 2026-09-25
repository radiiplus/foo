import { setting } from "./environment.ts";
import { parseRegistry, parseShard, type IndexEntry, type RegistryManifest } from "./indexer.ts";
import type { PackageRecord } from "./manifest.ts";

const defaultSource = "https://raw.githubusercontent.com/radiiplus/foo.registry/main";
const exactVersion = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?$/;

export type Catalog = {
  manifest: RegistryManifest;
  entries: IndexEntry[];
};

export type Discovery = (request: Request, route: string) => Promise<Response>;

export class CatalogError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export async function loadCatalog(requestFetch: typeof fetch = fetch): Promise<Catalog> {
  const source = (setting("REGISTRY_SOURCE") ?? defaultSource).replace(/\/$/, "");
  const manifest = parseRegistry(await readJson(`${source}/indexes/index.json`, requestFetch));
  const shards = await Promise.all(manifest.shards.map(async (descriptor) => {
    const entries = parseShard(await readText(`${source}/${descriptor.path}?v=${manifest.revision}`, requestFetch));
    if (entries.length !== descriptor.count) throw new CatalogError(`Registry shard count mismatch: ${descriptor.path}`, 502);
    return entries;
  }));
  const entries = shards.flat();
  if (entries.length !== manifest.count) throw new CatalogError("Registry package count mismatch", 502);
  for (let index = 1; index < entries.length; index += 1) {
    const previous = entries[index - 1];
    const current = entries[index];
    if (compare(previous.category, current.category) > 0 ||
        (previous.category === current.category && compare(previous.name, current.name) > 0)) {
      throw new CatalogError("Registry index is not deterministically sorted", 502);
    }
  }
  return { manifest, entries };
}

export async function handleDiscovery(request: Request, route: string, requestFetch: typeof fetch = fetch): Promise<Response> {
  const url = new URL(request.url);
  const catalog = await loadCatalog(requestFetch);
  if (route === "/search") return response(list(catalog, url.searchParams));
  if (route.startsWith("/category/")) {
    const category = segment(route, "/category/").toLowerCase();
    const parameters = new URLSearchParams(url.searchParams);
    parameters.set("category", category);
    return response(list(catalog, parameters));
  }
  if (route.startsWith("/tag/")) {
    const tag = segment(route, "/tag/").toLowerCase();
    const parameters = new URLSearchParams(url.searchParams);
    parameters.set("tag", tag);
    return response(list(catalog, parameters));
  }
  if (route.startsWith("/package/")) {
    const name = segment(route, "/package/");
    const selected = select(catalog, name, url.searchParams.get("version") ?? "");
    const record = await packageRecord(selected.path, catalog.manifest.revision, requestFetch);
    return response({
      schema: "foo.package-response/v1",
      registry: catalog.manifest.revision,
      package: record,
      versions: selected.entry.versions,
    });
  }
  if (route.startsWith("/resolve/")) {
    const name = segment(route, "/resolve/");
    return response(await resolve(catalog, name, url.searchParams.get("version") ?? "", requestFetch));
  }
  throw new CatalogError("Not found", 404);
}

function list(catalog: Catalog, parameters: URLSearchParams) {
  const query = (parameters.get("q") ?? "").trim().toLowerCase();
  const category = (parameters.get("category") ?? "").trim().toLowerCase();
  const tag = (parameters.get("tag") ?? "").trim().toLowerCase();
  const kind = (parameters.get("kind") ?? "").trim().toLowerCase();
  if (kind && kind !== "package" && kind !== "standard") throw new CatalogError("Invalid package kind", 400);
  const offset = integer(parameters.get("offset"), 0, 0, Number.MAX_SAFE_INTEGER);
  const limit = integer(parameters.get("limit"), 24, 1, 100);
  const sort = parameters.get("sort") ?? (query ? "relevance" : "category");
  if (!["relevance", "category", "recent", "name"].includes(sort)) throw new CatalogError("Invalid sort", 400);
  const matches = catalog.entries.filter((entry) => {
    const text = [entry.name, entry.description, entry.category, ...entry.tags, ...entry.exports].join(" ").toLowerCase();
    return (!query || text.includes(query)) && (!category || entry.category === category) &&
      (!tag || entry.tags.includes(tag)) && (!kind || entry.kind === kind);
  });
  matches.sort(sorter(sort, query));
  const packages = matches.slice(offset, offset + limit);
  return {
    schema: "foo.search/v1",
    registry: catalog.manifest.revision,
    query,
    filters: { category, tag, kind },
    sort,
    total: matches.length,
    offset,
    limit,
    next: offset + packages.length < matches.length ? offset + packages.length : null,
    packages,
    facets: facets(catalog.entries),
  };
}

async function resolve(catalog: Catalog, name: string, requested: string, requestFetch: typeof fetch) {
  const first = select(catalog, name, requested);
  const queue = [{ name, version: first.version, direct: true }];
  const records = new Map<string, PackageRecord & { direct: boolean }>();
  while (queue.length) {
    const requirement = queue.shift()!;
    const previous = records.get(requirement.name);
    if (previous) {
      if (previous.version !== requirement.version) {
        throw new CatalogError(`Dependency conflict for ${requirement.name}: ${previous.version} and ${requirement.version}`, 409);
      }
      if (requirement.direct) previous.direct = true;
      continue;
    }
    const selected = select(catalog, requirement.name, requirement.version);
    const record = await packageRecord(selected.path, catalog.manifest.revision, requestFetch);
    records.set(record.name, { ...record, direct: requirement.direct });
    for (const dependency of record.dependencies) {
      if (dependency.kind !== "runtime") continue;
      if (!exactVersion.test(dependency.version)) throw new CatalogError(`Non-exact dependency in ${record.name}: ${dependency.name}`, 502);
      queue.push({ name: dependency.name, version: dependency.version, direct: false });
    }
  }
  const packages = [...records.values()].sort((left, right) => compare(left.name, right.name));
  return {
    schema: "foo.resolution/v1",
    registry: catalog.manifest.revision,
    root: `${name}@${first.version}`,
    count: packages.length,
    packages,
  };
}

function select(catalog: Catalog, name: string, requested: string) {
  const entry = catalog.entries.find((candidate) => candidate.name === name);
  if (!entry) throw new CatalogError(`Package not found: ${name}`, 404);
  const version = requested || entry.version;
  if (!exactVersion.test(version)) throw new CatalogError("Version must be exact", 400);
  const selected = entry.versions.find((candidate) => candidate.version === version);
  if (!selected) throw new CatalogError(`Package version not found: ${name}@${version}`, 404);
  return { entry, version, path: selected.path };
}

async function packageRecord(path: string, revision: string, requestFetch: typeof fetch) {
  const source = (setting("REGISTRY_SOURCE") ?? defaultSource).replace(/\/$/, "");
  const value = await readJson(`${source}/${path}?v=${revision}`, requestFetch);
  if (!object(value) || value.schema !== "foo.package/v1" || typeof value.name !== "string" || typeof value.version !== "string" ||
      typeof value.description !== "string" || !Array.isArray(value.dependencies) || !Array.isArray(value.readme)) {
    throw new CatalogError(`Invalid package record: ${path}`, 502);
  }
  return value as unknown as PackageRecord;
}

function facets(entries: IndexEntry[]) {
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

function sorter(sort: string, query: string) {
  if (sort === "name") return (left: IndexEntry, right: IndexEntry) => compare(left.name, right.name);
  if (sort === "recent") return (left: IndexEntry, right: IndexEntry) => compare(right.updated, left.updated) || compare(left.name, right.name);
  if (sort === "relevance") return (left: IndexEntry, right: IndexEntry) => relevance(left, query) - relevance(right, query) || compare(left.name, right.name);
  return (left: IndexEntry, right: IndexEntry) => compare(left.category, right.category) || compare(left.name, right.name);
}

function relevance(entry: IndexEntry, query: string) {
  if (entry.name === query) return 0;
  if (entry.name.startsWith(query)) return 1;
  if (entry.name.includes(query)) return 2;
  if (entry.tags.includes(query)) return 3;
  if (entry.category.includes(query)) return 4;
  return 5;
}

function integer(value: string | null, fallback: number, minimum: number, maximum: number) {
  if (value === null || value === "") return fallback;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) throw new CatalogError("Invalid pagination", 400);
  return parsed;
}

function segment(route: string, prefix: string) {
  const encoded = route.slice(prefix.length);
  if (!encoded) throw new CatalogError("Package, category, or tag is required", 400);
  try {
    return decodeURIComponent(encoded);
  } catch {
    throw new CatalogError("Invalid route encoding", 400);
  }
}

async function readText(url: string, requestFetch: typeof fetch) {
  const response = await requestFetch(url, { headers: { accept: "application/json", "user-agent": "foo-registry-discovery" } });
  if (!response.ok) throw new CatalogError(response.status === 404 ? "Registry content not found" : "Registry content unavailable", response.status === 404 ? 404 : 502);
  return await response.text();
}

async function readJson(url: string, requestFetch: typeof fetch) {
  const text = await readText(url, requestFetch);
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new CatalogError("Registry content is not valid JSON", 502);
  }
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function compare(left: string, right: string) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function response(body: unknown) {
  return Response.json(body, { headers: { "access-control-allow-origin": "*", "cache-control": "public, max-age=60, s-maxage=300" } });
}
