import { registryOwner, type GitHubIdentity, type RegistryOwner } from "./identity.ts";

export type Dependency = {
  name: string;
  version: string;
  kind: "runtime" | "dev" | "optional" | "platform";
  platforms: string[];
};

export type PackageRecord = {
  schema: "foo.package/v1";
  kind: "package" | "standard";
  name: string;
  version: string;
  description: string;
  category: string;
  tags: string[];
  license: string;
  compatible: boolean;
  deprecated: string;
  platforms: string[];
  updated: string;
  owner: RegistryOwner;
  repository: string;
  revision: string;
  install: string;
  dependencies: Dependency[];
  readme: string[];
  source: SourceBundle;
  api: PublicApi;
};

export type PublicApi = {
  schema: "foo.api/v1";
  modules: Array<{
    name: string;
    path: string;
    summary: string;
    items: Array<{ kind: "function" | "type" | "constant" | "value"; name: string; declaration: string; documentation: string }>;
  }>;
};

export type SourceBundle = {
  format: "foo.source/v1";
  digest: string;
  files: Array<{ path: string; content: string }>;
};

const namePattern = /^(?:@[a-z0-9][a-z0-9-]{0,38}\/)?[a-z][a-z0-9-]{0,63}$/;
const tokenPattern = /^[a-z0-9][a-z0-9-]{0,31}$/;
const versionPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z.-]+))?$/;
const constraintPattern = /^(?:\^|~)?(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/;
const fields = new Set([
  "schema", "name", "version", "description", "category", "tags", "license", "compatible",
  "deprecated", "platforms", "updated", "repository", "revision", "install", "dependencies",
]);

export async function publication(value: unknown, identity: GitHubIdentity): Promise<PackageRecord> {
  if (!object(value) || value.schema !== "foo.publish/v1" || !object(value.manifest) || !Array.isArray(value.documentation) || !object(value.source) || !object(value.api)) {
    throw new TypeError("Invalid publication schema");
  }
  if (Object.keys(value).some((key) => !["schema", "manifest", "documentation", "source", "api"].includes(key))) {
    throw new TypeError("Unknown publication fields");
  }
  if (value.documentation.length < 100) throw new TypeError("Documentation must contain at least 100 lines");
  const readme = value.documentation.map((line, index) => text(line, `documentation[${index}]`));
  const manifest = value.manifest;
  const unknown = Object.keys(manifest).filter((key) => !fields.has(key));
  if (unknown.length) throw new TypeError(`Unknown manifest fields: ${unknown.join(", ")}`);
  if (manifest.schema !== "foo.package/v1") throw new TypeError("Invalid package schema");

  const name = text(manifest.name, "name").toLowerCase();
  if (!namePattern.test(name)) throw new TypeError("Invalid package name");
  if (name.startsWith("@") && name.slice(1, name.indexOf("/")) !== identity.login.toLowerCase()) {
    throw new TypeError("Package scope must match the authenticated GitHub login");
  }
  const version = text(manifest.version, "version");
  if (!versionPattern.test(version)) throw new TypeError("Invalid package version");
  const description = text(manifest.description, "description");
  if (description.length > 280) throw new TypeError("Description must be at most 280 characters");
  const category = text(manifest.category, "category").toLowerCase().replace(/\s+/g, " ");
  if (!/^[a-z0-9][a-z0-9 -]{0,63}$/.test(category)) throw new TypeError("Invalid category");
  if (typeof manifest.compatible !== "boolean") throw new TypeError("Invalid compatibility value");
  const updated = text(manifest.updated, "updated");
  const date = new Date(`${updated}T00:00:00Z`);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(updated) || Number.isNaN(date.valueOf()) || date.toISOString().slice(0, 10) !== updated) {
    throw new TypeError("Invalid updated date");
  }
  const repository = text(manifest.repository, "repository");
  try {
    if (new URL(repository).protocol !== "https:") throw new Error();
  } catch {
    throw new TypeError("Repository must be an HTTPS URL");
  }
  const revision = text(manifest.revision, "revision").toLowerCase();
  if (!/^[a-f0-9]{40}$/.test(revision)) throw new TypeError("Revision must be a full Git commit SHA");
  if (!Array.isArray(manifest.dependencies)) throw new TypeError("Dependencies must be an array");
  const dependencies = manifest.dependencies.map(dependency);
  dependencies.sort((left, right) => compare(left.name, right.name) || compare(left.kind, right.kind));
  const source = await sourceBundle(value.source);
  const api = publicApi(value.api, source);
  const owner = await registryOwner(identity);

  return {
    schema: "foo.package/v1",
    kind: "package",
    name,
    version,
    description,
    category,
    tags: tokens(manifest.tags, "tags"),
    license: text(manifest.license, "license"),
    compatible: manifest.compatible,
    deprecated: optional(manifest.deprecated, "deprecated"),
    platforms: tokens(manifest.platforms ?? [], "platforms"),
    updated,
    owner,
    repository,
    revision,
    install: text(manifest.install, "install"),
    dependencies,
    readme,
    source,
    api,
  };
}

function publicApi(value: Record<string, unknown>, source: SourceBundle): PublicApi {
  if (value.schema !== "foo.api/v1" || !Array.isArray(value.modules) || Object.keys(value).some((key) => !["schema", "modules"].includes(key))) {
    throw new TypeError("Invalid public API index");
  }
  const sourcePaths = new Set(source.files.filter((file) => file.path.endsWith(".iv")).map((file) => file.path));
  const modules = value.modules.map((module, moduleIndex) => {
    if (!object(module) || !Array.isArray(module.items) || Object.keys(module).some((key) => !["name", "path", "summary", "items"].includes(key))) {
      throw new TypeError(`Invalid API module at index ${moduleIndex}`);
    }
    const path = text(module.path, `api.modules[${moduleIndex}].path`);
    if (!sourcePaths.has(path)) throw new TypeError(`API module is not in the source bundle: ${path}`);
    const items = module.items.map((item, itemIndex) => {
      if (!object(item) || Object.keys(item).some((key) => !["kind", "name", "declaration", "documentation"].includes(key))) {
        throw new TypeError(`Invalid API item at ${moduleIndex}:${itemIndex}`);
      }
      const kind = item.kind;
      if (kind !== "function" && kind !== "type" && kind !== "constant" && kind !== "value") {
        throw new TypeError(`Invalid API item kind at ${moduleIndex}:${itemIndex}`);
      }
      const normalizedKind = kind as PublicApi["modules"][number]["items"][number]["kind"];
      return {
        kind: normalizedKind,
        name: text(item.name, `api.modules[${moduleIndex}].items[${itemIndex}].name`),
        declaration: text(item.declaration, `api.modules[${moduleIndex}].items[${itemIndex}].declaration`),
        documentation: optional(item.documentation, `api.modules[${moduleIndex}].items[${itemIndex}].documentation`),
      };
    });
    return {
      name: text(module.name, `api.modules[${moduleIndex}].name`),
      path,
      summary: optional(module.summary, `api.modules[${moduleIndex}].summary`),
      items,
    };
  });
  if (modules.length > 1000) throw new TypeError("Public API index has too many modules");
  return { schema: "foo.api/v1", modules };
}

async function sourceBundle(value: Record<string, unknown>): Promise<SourceBundle> {
  if (value.format !== "foo.source/v1" || !Array.isArray(value.files) ||
      Object.keys(value).some((key) => !["format", "digest", "files"].includes(key))) {
    throw new TypeError("Invalid source bundle");
  }
  if (value.files.length === 0 || value.files.length > 1000) throw new TypeError("Source must contain between 1 and 1000 files");
  const seen = new Set<string>();
  let total = 0;
  const files = value.files.map((file, index) => {
    if (!object(file) || Object.keys(file).some((key) => !["path", "content"].includes(key))) {
      throw new TypeError(`Invalid source file at index ${index}`);
    }
    const path = text(file.path, `source.files[${index}].path`).replace(/\\/g, "/");
    if (path.startsWith("/") || path.split("/").some((part) => !part || part === "." || part === "..")) {
      throw new TypeError(`Unsafe source path: ${path}`);
    }
    if (typeof file.content !== "string") throw new TypeError(`source.files[${index}].content must be a string`);
    const key = path.toLowerCase();
    if (seen.has(key)) throw new TypeError(`Duplicate source path: ${path}`);
    seen.add(key);
    const content = file.content.replace(/\r\n?/g, "\n");
    total += new TextEncoder().encode(path).length + new TextEncoder().encode(content).length;
    return { path, content };
  }).sort((left, right) => compare(left.path, right.path));
  if (total > 16 * 1024 * 1024) throw new TypeError("Source bundle exceeds 16 MiB");
  const canonical = files.map((file) => `${file.path}\0${file.content}\0`).join("");
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonical)));
  return {
    format: "foo.source/v1",
    digest: [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join(""),
    files,
  };
}

function dependency(value: unknown, index: number): Dependency {
  if (!object(value) || Object.keys(value).some((key) => !["name", "version", "kind", "platforms"].includes(key))) {
    throw new TypeError(`Invalid dependency at index ${index}`);
  }
  const name = text(value.name, `dependencies[${index}].name`).toLowerCase();
  if (!namePattern.test(name)) throw new TypeError(`Invalid dependency name: ${name}`);
  const kind = value.kind ?? "runtime";
  if (kind !== "runtime" && kind !== "dev" && kind !== "optional" && kind !== "platform") throw new TypeError("Invalid dependency kind");
  const version = text(value.version, `dependencies[${index}].version`);
  if (!constraintPattern.test(version)) throw new TypeError(`Invalid dependency constraint: ${version}`);
  return {
    name,
    version,
    kind,
    platforms: tokens(value.platforms ?? [], `dependencies[${index}].platforms`),
  };
}

function tokens(value: unknown, field: string) {
  if (!Array.isArray(value)) throw new TypeError(`${field} must be an array`);
  const normalized = value.map((item, index) => text(item, `${field}[${index}]`).toLowerCase());
  for (const item of normalized) if (!tokenPattern.test(item)) throw new TypeError(`Invalid ${field} value: ${item}`);
  return [...new Set(normalized)].sort(compare);
}

function text(value: unknown, field: string) {
  if (typeof value !== "string" || value.trim().length === 0) throw new TypeError(`${field} must be a non-empty string`);
  return value.trim();
}

function optional(value: unknown, field: string) {
  if (value === undefined) return "";
  if (typeof value !== "string") throw new TypeError(`${field} must be a string`);
  return value.trim();
}

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function compare(left: string, right: string) {
  return left < right ? -1 : left > right ? 1 : 0;
}
