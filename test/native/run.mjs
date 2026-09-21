import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const executable = process.platform === "win32" ? "nim.exe" : "nim";
const candidates = [process.env.NIM_BIN];
const toolchains = join(homedir(), ".choosenim", "toolchains");
if (existsSync(toolchains)) {
  for (const version of readdirSync(toolchains).sort().reverse())
    candidates.push(join(toolchains, version, "bin", executable));
}
candidates.push(executable);
const compiler = candidates.find(candidate => candidate && (candidate === executable || existsSync(candidate))) ?? executable;
const files = readdirSync(join(root, "test"), { recursive: true, withFileTypes: true })
  .filter(entry => entry.isFile() && entry.name.endsWith(".nim"))
  .map(entry => join(entry.parentPath, entry.name))
  .sort();
const output = join(root, ".artifacts", "native-tests");
mkdirSync(output, { recursive: true });
const results = [];

for (const file of files) {
  const name = relative(join(root, "test"), file).replaceAll("\\", "/");
  const id = name.replace(/\.nim$/, "").replaceAll("/", "-");
  const binary = join(output, id + (process.platform === "win32" ? ".exe" : ""));
  const cache = join(output, "cache", id);
  mkdirSync(cache, { recursive: true });
  const args = ["c", "-r", "--hints:off", "--warnings:off", `--path:${root}`, `--nimcache:${cache}`, `--out:${binary}`];
  if (process.platform === "win32") args.push("--cc:clang");
  args.push(file);
  const started = performance.now();
  const run = spawnSync(compiler, args, { cwd: root, encoding: "utf8", timeout: 180000, windowsHide: true });
  const result = { file: name, passed: run.status === 0, code: run.status, elapsed: performance.now() - started,
    stdout: run.stdout ?? "", stderr: run.stderr ?? "", error: run.error?.message };
  results.push(result);
  console.log(`${result.passed ? "PASS" : "FAIL"} ${name} (${Math.round(result.elapsed)} ms)`);
  if (!result.passed) process.stderr.write(result.stderr || result.stdout || result.error || "Unknown native test failure\n");
}

writeFileSync(join(output, "results.json"), JSON.stringify(results, null, 2) + "\n");
console.log(`${results.filter(result => result.passed).length}/${results.length} native tests passed.`);
if (results.some(result => !result.passed)) process.exitCode = 1;
