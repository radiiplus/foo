import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const library = join(root, "lib");
const output = join(root, "registry", "standard.json");
const version = JSON.parse(await readFile(join(root, "package.json"), "utf8")).version;
const previous = JSON.parse(await readFile(output, "utf8").catch(() => '{"packages":[]}'));
const previousPackages = new Map(previous.packages.map((record) => [record.name, record]));
const owner = {
  signature: "v1.m8QuzQNcvsKITl_Jyz0qn5dA9ExcXMyPzLgup9CRrU4",
  login: "radiiplus",
};

const packages = [];
for (const path of await sourceFiles(library)) {
  const module = relative(library, path).split(sep).join("/").replace(/\.iv$/, "");
  const content = (await readFile(path, "utf8")).replace(/\r\n?/g, "\n");
  const sourcePath = `lib/${module}.iv`;
  const source = {
    format: "foo.source/v1",
    digest: hash(`${sourcePath}\0${content}\0`),
    files: [{ path: sourcePath, content }],
  };
  const earlier = previousPackages.get(`lib/${module}`);
  const updated = earlier?.version === version && earlier.source?.digest === source.digest
    ? earlier.updated : new Date().toISOString().slice(0, 10);
  const revision = git("log", "-1", "--format=%H", "--", sourcePath) || git("rev-parse", "HEAD");
  const description = summary(content) || `FOO standard library module ${module}.`;
  const install = module.includes("/") ? `use "${module}".` : `use ${module}.`;
  packages.push({
    schema: "foo.package/v1", kind: "standard", name: `lib/${module}`, version,
    description, category: "standard library",
    tags: ["standard", ...new Set(module.split("/"))].sort(compare),
    license: "MIT OR Apache-2.0", compatible: true, deprecated: "",
    platforms: module === "os/windows" ? ["windows"] : module === "os/unix" ? ["linux", "macos"] : ["all"],
    updated, owner, repository: "https://github.com/radiiplus/foo", revision,
    install, dependencies: [], readme: [description, `Import this module with ${install}`], source,
    api: { schema: "foo.api/v1", modules: [{
      name: sourcePath.replace(/\.iv$/, ""), path: sourcePath,
      summary: description, items: declarations(content),
    }] },
  });
}
const entries = packages.map((record) => ({
  schema: "foo.entry/v1", kind: record.kind, name: record.name,
  version: record.version, description: record.description,
  category: record.category, tags: record.tags, license: record.license,
  compatible: record.compatible, deprecated: record.deprecated,
  platforms: record.platforms, updated: record.updated, owner: record.owner,
  repository: record.repository, revision: record.revision,
  exports: [...new Set(record.api.modules.flatMap((module) => module.items.map((item) => item.name)))].sort(compare),
  path: "registry/standard.json",
  versions: [{ version: record.version, updated: record.updated, deprecated: "", path: "registry/standard.json" }],
}));
const catalog = {
  schema: "foo.standard-catalog/v1",
  revision: hash(JSON.stringify(packages)),
  count: packages.length,
  entries,
  packages,
};
await mkdir(dirname(output), { recursive: true });
const encoded = `${JSON.stringify(catalog, null, 2)}\n`;
if (process.argv.includes("--check")) {
  const current = await readFile(output, "utf8").catch(() => "");
  if (current !== encoded) throw Error("FOO standard catalog is stale; run npm run registry:standard");
  console.log(`FOO standard catalog is current (${catalog.count} modules)`);
} else {
  await writeFile(output, encoded);
  console.log(`Indexed ${catalog.count} standard modules in ${relative(root, output)}`);
}

async function sourceFiles(directory) {
  const found = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) found.push(...await sourceFiles(path));
    else if (entry.isFile() && entry.name.endsWith(".iv")) found.push(path);
  }
  return found.sort(compare);
}

function declarations(source) {
  const lines = source.split("\n");
  const items = [];
  let comments = [];
  for (let index = 0; index < lines.length; index += 1) {
    const current = lines[index].trim();
    if (current.startsWith("--")) {
      const comment = commentText(current);
      if (comment) comments.push(comment);
      continue;
    }
    if (!current) continue;
    if (!current.startsWith("public ")) { comments = []; continue; }
    let declaration = current;
    if (/^public define\s+/.test(current) && current.includes("{")) {
      let depth = braces(current);
      while (depth > 0 && index + 1 < lines.length) {
        declaration += `\n${lines[++index].trimEnd()}`;
        depth += braces(lines[index]);
      }
    } else if (/^public function\s+/.test(current)) {
      while (!declaration.includes("{") && index + 1 < lines.length) declaration += ` ${lines[++index].trim()}`;
      declaration = declaration.split("{")[0].trim().replace(/[.]$/, "") + ".";
    } else {
      while (!declaration.trimEnd().endsWith(".") && index + 1 < lines.length) declaration += ` ${lines[++index].trim()}`;
    }
    const match = declaration.match(/^public\s+(?:use\s+"[^"]+"\s+)?(function|define|constant|dynamic)\s+([A-Za-z][A-Za-z0-9_]*)/);
    if (match) items.push({
      kind: match[1] === "define" ? "type" : match[1] === "dynamic" ? "value" : match[1],
      name: match[2], declaration, documentation: comments.join(" "),
    });
    comments = [];
  }
  return items;
}

function braces(value) {
  return [...value].reduce((depth, char) => depth + (char === "{" ? 1 : char === "}" ? -1 : 0), 0);
}

function summary(source) {
  const lines = [];
  for (const line of source.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) { if (lines.length) break; continue; }
    if (!trimmed.startsWith("--") || (trimmed.startsWith("---") && lines.length)) break;
    const comment = commentText(trimmed);
    if (comment) lines.push(comment);
  }
  return lines.join(" ");
}

function commentText(value) {
  return value.replace(/^---?!?\s?/, "").replace(/\s*---$/, "").trim();
}

function hash(value) {
  return createHash("sha256").update(value).digest("hex");
}

function git(...args) {
  return execFileSync("git", ["-C", root, ...args], { encoding: "utf8" }).trim();
}

function compare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}
