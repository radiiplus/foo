import { readdirSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const library = join(root, "std");
const launcher = join(root, "bin", "foo.mjs");
const files = readdirSync(library, { recursive: true, withFileTypes: true })
  .filter(entry => entry.isFile() && entry.name.endsWith(".iv"))
  .map(entry => join(entry.parentPath, entry.name))
  .sort();

let failures = 0;
for (const file of files) {
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

console.log(`${files.length - failures}/${files.length} standard modules checked.`);
if (failures > 0) process.exitCode = 1;
