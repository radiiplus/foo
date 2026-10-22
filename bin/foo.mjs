#!/usr/bin/env node
import { chmodSync as chmod, existsSync as exists, readFileSync as read, statSync as stat } from "node:fs";
import { spawnSync as invoke } from "node:child_process";
import { arch } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath as filename } from "node:url";
import * as artifacts from '../tools/artifacts.mjs';
import { run as runSharedBuild } from '../tools/worker.mjs';

if (process.argv[2] === 'dev' && process.argv[3] === 'clean') {
  const options = process.argv.slice(4);
  if (!options.length || options.some(option => !['--dry-run', '--all'].includes(option)))
    throw Error('Usage: foo dev clean --dry-run | --all');
  const report = artifacts.clean({ all: options.includes('--all'), dryRun: options.includes('--dry-run') });
  for (const item of report.candidates)
    console.log(`${options.includes('--all') && !options.includes('--dry-run') ? 'Removed' : 'Would remove'} ${item.directory} (${item.bytes} bytes)`);
  console.log(`${report.candidates.length} owned runs, ${report.skipped.length} skipped; root: ${report.root}`);
  process.exit(0);
}

const root = resolve(dirname(filename(import.meta.url)), "..");
if (process.argv[2] === 'test' && !process.env.FOO_TEST_ARTIFACT_DIR &&
    process.cwd() === root)
  process.env.FOO_TEST_ARTIFACT_DIR = artifacts.create('test');
const executable = process.platform === "win32" ? "foo.exe" : "foo";
const candidates = [
  process.env.FOO_COMPILER,
  resolve(root, "bin", executable),
  resolve(root, ".artifacts", "native", `${process.platform}-${arch()}`, executable),
  resolve(root, ".artifacts", "compiler", "bin", executable),
  resolve(root, ".artifacts", "native", executable),
].filter(Boolean);
const available = candidates.filter(exists);
const source = resolve(root, ".artifacts", "native", executable);
const cached = resolve(root, ".artifacts", "native", `${process.platform}-${arch()}`, executable);
if (available.includes(source) && available.includes(cached) &&
    stat(source).mtimeMs > stat(cached).mtimeMs) {
  available.splice(available.indexOf(source), 1);
  available.splice(available.indexOf(cached), 0, source);
}
if (!process.env.FOO_COMPILER && available.includes(source)) {
  available.splice(available.indexOf(source), 1);
  available.unshift(source);
}
if (available.length === 0) {
  console.error("The native FOO compiler is missing. Run npm run native:build.");
  process.exit(1);
}
const expected = JSON.parse(read(resolve(root, "package.json"), "utf8")).version;
const versions = new Map();
const compiler = available.find((candidate) => {
  const check = invoke(candidate, ["version"], {
    encoding: "utf8",
    windowsHide: true,
  });
  const output = `${check.stdout ?? ""}\n${check.stderr ?? ""}`;
  const match = output.match(/compiler\s+([^\s]+)/);
  versions.set(candidate, match?.[1] ?? "unreadable");
  return check.status === 0 && match?.[1] === expected;
});
if (!compiler) {
  const found = [...versions].map(([path, version]) => `${path} (${version})`).join("\n  ");
  console.error(`The available FOO compiler does not match package ${expected}.\n  ${found}\nRun npm run native:build.`);
  process.exit(1);
}
if (process.platform !== "win32") {
  try {
    const mode = stat(compiler).mode;
    if ((mode & 0o111) === 0) chmod(compiler, mode | 0o111);
  } catch {
    // spawnSync reports a concrete permission error when the filesystem is read-only.
  }
}

const cache = process.env.FOO_CACHE_HOME
  ? resolve(process.env.FOO_CACHE_HOME)
  : resolve(process.cwd(), ".artifacts", "cache");
const legacyToolchain = resolve(root, "toolchain.json");
if (exists(legacyToolchain)) {
  const version = JSON.parse(read(legacyToolchain, "utf8")).zig;
  if (version) {
    process.env.ZIG_GLOBAL_CACHE_DIR ||= resolve(cache, "zig", version);
    process.env.ZIG_LOCAL_CACHE_DIR ||= resolve(process.cwd(), ".artifacts/cache/local");
  }
}
let scriptedBuild = false;
if (exists(resolve(process.cwd(), 'project.ivc'))) scriptedBuild = true;
if (['build', 'check'].includes(process.argv[2]) &&
    !scriptedBuild && !process.argv.includes('--watch') &&
    process.env.FOO_BUILD_WORKER !== 'off') {
  try { process.exit(await runSharedBuild(compiler, process.argv.slice(2), process.cwd(), process.env)); }
  catch (error) { console.error(error.message); process.exit(1); }
}
const result = invoke(compiler, process.argv.slice(2), {
  cwd: process.cwd(),
  env: process.env,
  stdio: "inherit",
  windowsHide: true,
});
if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status ?? 1);
