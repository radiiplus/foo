#!/usr/bin/env node
import { chmodSync, existsSync, readFileSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const executable = process.platform === "win32" ? "foo.exe" : "foo";
const candidates = [
  process.env.FOO_COMPILER,
  resolve(root, "bin", executable),
  resolve(root, ".artifacts", "native", executable),
].filter(Boolean);
const compiler = candidates.find(existsSync);
if (!compiler) {
  console.error("The native FOO compiler is missing. Run npm run native:build.");
  process.exit(1);
}
if (process.platform !== "win32") {
  try {
    const mode = statSync(compiler).mode;
    if ((mode & 0o111) === 0) chmodSync(compiler, mode | 0o111);
  } catch {
    // spawnSync reports a concrete permission error when the filesystem is read-only.
  }
}

const zigVersion = JSON.parse(readFileSync(resolve(root, "toolchain.json"), "utf8")).zig;
const cacheRoot = process.env.FOO_CACHE_HOME
  ? resolve(process.env.FOO_CACHE_HOME)
  : resolve(homedir(), ".foo", "cache");
process.env.ZIG_GLOBAL_CACHE_DIR ||= resolve(cacheRoot, "zig", zigVersion);
process.env.ZIG_LOCAL_CACHE_DIR ||= resolve(process.cwd(), ".artifacts/cache/local");
const result = spawnSync(compiler, process.argv.slice(2), {
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
