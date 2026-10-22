import { value as option } from './arguments.mjs';
import { spawnSync as invoke } from "node:child_process";
import { createHash as hasher } from "node:crypto";
import { copyFileSync as copy, existsSync as exists, lstatSync as lstat, mkdirSync as mkdir, readFileSync as read, writeFileSync as write } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath as filename } from "node:url";

const root = resolve(dirname(filename(import.meta.url)), "..");
const roots = new Set([
  ".github", "assets", "benchmark", "bin", "docs", "editors", "examples",
  "installers", "lib", "registry", "specs", "src", "test", "toolchain", "tools", "vendor",
]);
const included = new Set([
  ".env.sign.example", ".gitattributes", ".gitignore", "CHANGELOG.md",
  "CODE_OF_CONDUCT.md", "CONTRIBUTING.md", "LICENSE", "LICENSE-APACHE",
  "LICENSE-MIT", "README.md", "SECURITY.md", "package.json",
  "package-lock.json", "project.ivc", "toolchain.json",
]);
const generated = new Set([
  ".artifacts", ".foo", "coverage", "dist", "node_modules",
  "output", "release", "target", "zig-cache", "zig-out",
]);

function git(args) {
  const result = invoke("git", args, { cwd: root, maxBuffer: 32 * 1024 * 1024 });
  if (result.error || result.status !== 0)
    throw Error(result.error?.message || result.stderr.toString() || `git exited ${result.status}`);
  return result.stdout;
}


if (process.argv.includes("--help")) {
  console.log("Usage: node tools/source.mjs [--output DIRECTORY]");
  console.log("Stages current source files and creates a local .tar.gz candidate.");
  process.exit(0);
}

const output = resolve(option("--output") || join(root, ".artifacts", "release-source", "foo-source-candidate"));
const archive = `${output}.tar.gz`;
if (output === root || !relative(root, output) || exists(output) || exists(archive))
  throw Error(`Choose a new source-package destination: ${output}`);

const listed = git(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--"])
  .toString("utf8").split("\0").filter(Boolean);
const selected = [...new Set(listed.filter(path => {
  const parts = path.split("/");
  if (parts.length === 1) return included.has(path);
  return roots.has(parts[0]) && !parts.some(part => generated.has(part)) &&
    !path.startsWith("registry/repository/indexes/");
}))].sort();

for (const required of ["src/main.nim", "src/backend/qbe/driver.nim", "src/runtime/qbe.c", "lib/sequence.iv",
    "tools/native.mjs", "tools/build.mjs", "tools/source.mjs", "package.json",
    "package-lock.json", "toolchain.json", "toolchain/assets.json", "vendor/blake3/c/blake3.c"])
  if (!selected.includes(required)) throw Error(`Source package is missing ${required}`);

const version = JSON.parse(read(join(root, "package.json"), "utf8")).version;
const lock = JSON.parse(read(join(root, "package-lock.json"), "utf8"));
if (version !== lock.version || version !== lock.packages?.[""]?.version)
  throw Error("Release versions differ across package.json and package-lock.json");
const commit = git(["rev-parse", "HEAD"]).toString("utf8").trim();
const dirty = git(["status", "--porcelain=v1", "--untracked-files=normal"])
  .toString("utf8").trim().length > 0;

mkdir(output, { recursive: true });
const files = [];
for (const path of selected) {
  const source = join(root, ...path.split("/"));
  if (!exists(source)) continue;
  const info = lstat(source);
  if (!info.isFile()) throw Error(`Source package cannot include a non-file: ${path}`);
  const destination = join(output, ...path.split("/"));
  mkdir(dirname(destination), { recursive: true });
  copy(source, destination);
  const bytes = read(destination);
  files.push({ path, bytes: bytes.length, sha256: hasher("sha256").update(bytes).digest("hex") });
}

const manifest = { format: "foo.source", version: 1, compiler: version,
  commit, dirty, files };
write(join(output, "source.json"), JSON.stringify(manifest, null, 2) + "\n");
const packed = invoke("tar", ["-czf", archive, "-C", dirname(output),
  output.slice(dirname(output).length + 1)], { cwd: root, stdio: "inherit" });
if (packed.error || packed.status !== 0)
  throw Error(packed.error?.message || `tar exited ${packed.status}`);
console.log(`Staged ${files.length} source files from ${commit.slice(0, 12)}${dirty ? " (dirty worktree)" : ""}`);
console.log(`Source directory: ${output}`);
console.log(`Source archive: ${archive}`);
