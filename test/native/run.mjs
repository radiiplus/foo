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
const base = join(root, ".artifacts", "native-tests");
const run = `run-${process.pid}-${Date.now()}`;
const output = join(base, run);
const temporary = join(output, "temp");
mkdirSync(output, { recursive: true });
mkdirSync(temporary, { recursive: true });
const environment = { ...process.env, TEMP: temporary, TMP: temporary,
  TMPDIR: temporary, FOOTESTID: run };
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
  const execution = spawnSync(compiler, args, { cwd: root, env: environment,
    encoding: "utf8", timeout: 180000, windowsHide: true });
  const result = { file: name, passed: execution.status === 0,
    code: execution.status, elapsed: performance.now() - started,
    stdout: execution.stdout ?? "", stderr: execution.stderr ?? "",
    error: execution.error?.message };
  results.push(result);
  console.log(`${result.passed ? "PASS" : "FAIL"} ${name} (${Math.round(result.elapsed)} ms)`);
  if (!result.passed) process.stderr.write(result.stderr || result.stdout || result.error || "Unknown native test failure\n");
}

const report = JSON.stringify(results, null, 2) + "\n";
writeFileSync(join(output, "results.json"), report);
writeFileSync(join(base, "results.json"), report);
console.log(`${results.filter(result => result.passed).length}/${results.length} native tests passed.`);
if (results.some(result => !result.passed)) process.exitCode = 1;
