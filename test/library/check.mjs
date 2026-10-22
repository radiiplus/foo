import { readFileSync as read } from "node:fs";
import { files } from '../../tools/tree.mjs';
import { basename, dirname, join, relative, resolve } from "node:path";
import { spawnSync as invoke } from "node:child_process";
import { fileURLToPath as filename } from "node:url";

const root = resolve(dirname(filename(import.meta.url)), "../..");
const library = join(root, "lib");
const launcher = join(root, "bin", "foo.mjs");
const modules = files(library, ".iv").sort();
for (const directory of [library, join(root, "test", "library")]) {
  for (const file of files(directory, ".iv")) {
    const source = read(file, "utf8");
    const declarations = [...source.matchAll(/^\s*(?:(?:public|use "[^"]+")\s+)*(define|function|constant|dynamic)\s+([A-Za-z][A-Za-z0-9_]*)/gm)]
      .map(match => ({kind: match[1], name: match[2]}));
    const names = declarations.map(item => item.name);
    if (directory === library && names.includes('join_into') && !names.includes('join')) {
      console.error(`Missing single-word alias for join_into in ${relative(root, file)}`);
      process.exitCode = 1;
    }
    const mixed = names.filter(name => name !== 'join_into' &&
      /_|[a-z][A-Z]|[A-Z][a-z]+[A-Z]/.test(name));
    const invalidFunction = directory === library ? declarations.find(item =>
      item.kind === 'function' && item.name !== 'join_into' &&
      item.name !== item.name.toLowerCase()) : null;
    const invalidType = directory === library ? declarations.find(item =>
      item.kind === 'define' &&
      item.name.slice(1) !== item.name.slice(1).toLowerCase()) : null;
    const capital = directory === library
      ? source.match(/^public (?:(?:use "[^"]+" )?function|define|constant) [A-Z][A-Za-z0-9]*/gm) : null;
    const valid = /^[a-z]+\.iv$/.test(basename(file)) || basename(file) === "base64.iv";
    if (!valid || mixed.length || invalidFunction || invalidType || capital) {
      console.error(`Invalid FOO name in ${relative(root, file)}: ${mixed.length ? mixed.join(", ") : invalidFunction?.name ?? invalidType?.name ?? capital?.join(", ") ?? basename(file)}`);
      process.exitCode = 1;
    }
  }
}

const names = invoke("rg", ["--files", "--hidden", "-g", "*.iv", "-g", "*.md",
  "-g", "*.nim", "-g", "*.c", "-g", "*.h", "-g", "*.mjs", "-g", "*.cjs",
  "-g", "*.s", "-g", "*.S",
  "-g", "!vendor/**", "-g", "!.github/**", "-g", "!CODE_OF_CONDUCT.md",
  "-g", "!.git/**", "-g", "!.artifacts/**",
  "-g", "!node_modules/**", "-g", "!**/.artifacts/**",
  "-g", "!**/output/**", "-g", "!**/release/**", "-g", "!dist/**",
  "-g", "!benchmark/features/**"],
  { cwd: root, encoding: "utf8", windowsHide: true });
if (names.status !== 0) throw Error(names.stderr || "FOO filename scan failed");
for (const path of names.stdout.trim().split(/\r?\n/)) {
  const normalized = path.replaceAll("\\","/");
  const name = basename(path);
  const valid = name.endsWith(".iv")
    ? /^[a-z0-9]+\.iv$/.test(name)
    : name.endsWith(".md") ? /^[A-Za-z]+\.md$/.test(name)
    : !/^(?:src|test|tools)\//.test(normalized) || !name.includes("_");
  const directoryValid = !normalized.startsWith("test/") ||
    normalized.split("/").slice(1, -1).every(part => !/[-_]/.test(part));
  if (!valid || !directoryValid) {
    console.error(`Invalid source name: ${path}`);
    process.exitCode = 1;
  }
  if (!name.endsWith(".iv")) continue;
  const protectedNames = new Set([
    "lib/joining.iv:join_into",
    "lib/text.iv:join_into",
    "test/backend/qbe/fixtures/placement.iv:cpu_page",
    "test/backend/qbe/fixtures/project/shared/src/library.iv:native_answer",
  ]);
  const source = read(join(root, path), "utf8");
  for (const match of source.matchAll(/^\s*(?:(?:public|use "[^"]+")\s+)*(?:define|function|constant|dynamic)\s+([A-Za-z][A-Za-z0-9_]*)/gm)) {
    const binding = match[1];
    if (/_|[a-z][A-Z]|[A-Z][a-z]+[A-Z]/.test(binding) &&
        !protectedNames.has(`${normalized}:${binding}`)) {
      console.error(`Invalid FOO binding in ${normalized}: ${binding}`);
      process.exitCode = 1;
    }
  }
}

let failures = 0;
if (process.argv.includes('--names-only')) {
  console.log('FOO source names checked.');
  process.exit(process.exitCode ?? 0);
}
for (const file of modules) {
  const name = relative(root, file).replaceAll("\\", "/");
  const result = invoke(process.execPath,
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
