import { readFileSync, readdirSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const library = join(root, "lib");
const launcher = join(root, "bin", "foo.mjs");
function files(directory, extension) {
  return readdirSync(directory, { recursive: true, withFileTypes: true })
    .filter(entry => entry.isFile() && entry.name.endsWith(extension))
    .map(entry => join(entry.parentPath, entry.name));
}

const modules = files(library, ".iv").sort();
for (const directory of [library, join(root, "test", "library"), join(root, "benchmark")]) {
  for (const file of files(directory, ".iv")) {
    const source = readFileSync(file, "utf8");
    const names = [...source.matchAll(/^\s*(?:(?:public|use "[^"]+")\s+)*(?:define|function|constant|dynamic)\s+([A-Za-z][A-Za-z0-9_]*)/gm)]
      .map(match => match[1]);
    const mixed = names.filter(name => /_|[a-z][A-Z]|[A-Z][a-z]+[A-Z]/.test(name));
    const capitalExport = directory === library
      ? source.match(/^public (?:(?:use "[^"]+" )?function|define|constant) [A-Z][A-Za-z0-9]*/gm) : null;
    const validName = /^[a-z]+\.iv$/.test(basename(file)) || basename(file) === "base64.iv";
    if (!validName || mixed.length || capitalExport) {
      console.error(`Invalid FOO name in ${relative(root, file)}: ${mixed.length ? mixed.join(", ") : capitalExport?.join(", ") ?? basename(file)}`);
      process.exitCode = 1;
    }
  }
}

const names = spawnSync("rg", ["--files", "--hidden", "-g", "*.iv", "-g", "*.md",
  "-g", "!vendor/**", "-g", "!.github/**", "-g", "!CODE_OF_CONDUCT.md",
  "-g", "!.git/**", "-g", "!.artifacts/**",
  "-g", "!node_modules/**", "-g", "!output/**", "-g", "!dist/**"],
  { cwd: root, encoding: "utf8", windowsHide: true });
if (names.status !== 0) throw Error(names.stderr || "FOO filename scan failed");
for (const path of names.stdout.trim().split(/\r?\n/)) {
  const name = basename(path);
  const valid = name.endsWith(".iv")
    ? /^[a-z0-9]+\.iv$/.test(name)
    : /^[A-Za-z]+\.md$/.test(name);
  if (!valid) {
    console.error(`Invalid source name: ${path}`);
    process.exitCode = 1;
  }
}

let failures = 0;
for (const file of modules) {
  const name = relative(root, file).replaceAll("\\", "/");
  const result = spawnSync(process.execPath,
    [launcher, "check", file, "--json"],
    { cwd: root, encoding: "utf8", windowsHide: true });
  const passed = result.status === 0;
  console.log(`${passed ? "PASS" : "FAIL"} ${name}`);
  if (!passed) {
    failures += 1;
    process.stderr.write(result.stderr || result.stdout ||
      result.error?.message || "Unknown standard-library check failure\n");
  }
}

console.log(`${modules.length - failures}/${modules.length} standard modules checked.`);
if (failures > 0) process.exitCode = 1;
