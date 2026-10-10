import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const roots = new Set([
  ".github", "assets", "benchmark", "bin", "docs", "editors", "examples",
  "installers", "lib", "registry", "specs", "src", "test", "tools", "vendor",
]);
const rootFiles = new Set([
  ".env.sign.example", ".gitattributes", ".gitignore", "CHANGELOG.md",
  "CODE_OF_CONDUCT.md", "CONTRIBUTING.md", "LICENSE", "LICENSE-APACHE",
  "LICENSE-MIT", "README.md", "SECURITY.md", "package.json",
  "package-lock.json", "project.json", "toolchain.json",
]);
const generated = new Set([
  ".artifacts", ".foo", "coverage", "dist", "node_modules",
  "output", "release", "target", "zig-cache", "zig-out",
]);

function git(args) {
  const result = spawnSync("git", args, { cwd: root, maxBuffer: 32 * 1024 * 1024 });
  if (result.error || result.status !== 0)
    throw Error(result.error?.message || result.stderr.toString() || `git exited ${result.status}`);
  return result.stdout;
}

function option(name) {
  const inline = process.argv.find(argument => argument.startsWith(`${name}=`));
  if (inline) return inline.slice(name.length + 1);
  const index = process.argv.indexOf(name);
  if (index < 0) return "";
  const value = process.argv[index + 1];
  if (!value || value.startsWith("--")) throw Error(`${name} needs a directory`);
  return value;
}

if (process.argv.includes("--help")) {
  console.log("Usage: node tools/source.mjs [--output DIRECTORY]");
  console.log("Stages current source files and creates a local .tar.gz candidate.");
  process.exit(0);
}

const output = resolve(option("--output") || join(root, ".artifacts", "release-source", "foo-source-candidate"));
const archive = `${output}.tar.gz`;
if (output === root || !relative(root, output) || existsSync(output) || existsSync(archive))
  throw Error(`Choose a new source-package destination: ${output}`);

const listed = git(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"])
  .toString("utf8").split("\0").filter(Boolean);
const selected = [...new Set(listed.filter(path => {
  const parts = path.split("/");
  if (parts.length === 1) return rootFiles.has(path);
  return roots.has(parts[0]) && !parts.some(part => generated.has(part)) &&
    !path.startsWith("registry/repository/indexes/");
}))].sort();

for (const required of ["src/main.nim", "src/backend/zig/library.zig", "lib/sequence.iv",
    "tools/native.mjs", "tools/build.mjs", "tools/source.mjs", "package.json",
    "package-lock.json", "toolchain.json", "vendor/blake3/c/blake3.c"])
  if (!selected.includes(required)) throw Error(`Source package is missing ${required}`);

const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
const projectVersion = JSON.parse(readFileSync(join(root, "project.json"), "utf8")).version;
const lock = JSON.parse(readFileSync(join(root, "package-lock.json"), "utf8"));
if (version !== projectVersion || version !== lock.version ||
    version !== lock.packages?.[""]?.version)
  throw Error("Release versions differ across package.json, package-lock.json, and project.json");
const commit = git(["rev-parse", "HEAD"]).toString("utf8").trim();
const dirty = git(["status", "--porcelain=v1", "--untracked-files=normal"])
  .toString("utf8").trim().length > 0;

mkdirSync(output, { recursive: true });
const files = [];
for (const path of selected) {
  const source = join(root, ...path.split("/"));
  if (!existsSync(source)) continue;
  const info = lstatSync(source);
  if (!info.isFile()) throw Error(`Source package cannot include a non-file: ${path}`);
  const destination = join(output, ...path.split("/"));
  mkdirSync(dirname(destination), { recursive: true });
  copyFileSync(source, destination);
  const bytes = readFileSync(destination);
  files.push({ path, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") });
}

const manifest = { format: "foo.source", version: 1, compiler: version,
  commit, dirty, files };
writeFileSync(join(output, "source.json"), JSON.stringify(manifest, null, 2) + "\n");
const packed = spawnSync("tar", ["-czf", archive, "-C", dirname(output),
  output.slice(dirname(output).length + 1)], { cwd: root, stdio: "inherit" });
if (packed.error || packed.status !== 0)
  throw Error(packed.error?.message || `tar exited ${packed.status}`);
console.log(`Staged ${files.length} source files from ${commit.slice(0, 12)}${dirty ? " (dirty worktree)" : ""}`);
console.log(`Source directory: ${output}`);
console.log(`Source archive: ${archive}`);
