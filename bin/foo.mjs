#!/usr/bin/env node
import { chmodSync, existsSync, readFileSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { arch, homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const executable = process.platform === "win32" ? "foo.exe" : "foo";
const candidates = [
  process.env.FOO_COMPILER,
  resolve(root, "bin", executable),
  resolve(root, ".artifacts", "native", executable),
  resolve(root, ".artifacts", "native", `${process.platform}-${arch()}`, executable),
].filter(Boolean);
const available = candidates.filter(existsSync);
if (available.length === 0) {
  console.error("The native FOO compiler is missing. Run npm run native:build.");
  process.exit(1);
}
const expected = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8")).version;
const versions = new Map();
const compiler = available.find((candidate) => {
  const check = spawnSync(candidate, ["version"], {
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
