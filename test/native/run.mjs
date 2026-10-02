import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { availableParallelism, homedir, totalmem } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { spawn } from "node:child_process";
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
const selected = process.argv.find(argument => argument.startsWith("--jobs="))?.slice(7)
  ?? process.env.FOO_TEST_JOBS;
const requested = Number.parseInt(selected ?? "", 10);
const memoryJobs = Math.max(1, Math.floor(totalmem() / (3 * 1024 ** 3)));
const automatic = Math.min(4, Math.max(1, availableParallelism() - 1), memoryJobs);
const jobs = Math.min(files.length,
  Number.isFinite(requested) && requested > 0 ? requested : automatic);
const selectedTimeout = Number.parseInt(process.env.FOO_TEST_TIMEOUT ?? "", 10);
const timeout = Number.isFinite(selectedTimeout) && selectedTimeout > 0
  ? selectedTimeout : 300000;
const results = [];

console.log(`Running ${files.length} native tests with ${jobs} jobs.`);

function execute(file) {
  const name = relative(join(root, "test"), file).replaceAll("\\", "/");
  const id = name.replace(/\.nim$/, "").replaceAll("/", "-");
  const binary = join(output, id + (process.platform === "win32" ? ".exe" : ""));
  const cache = join(output, "cache", id);
  const temp = join(temporary, id);
  mkdirSync(cache, { recursive: true });
  mkdirSync(temp, { recursive: true });
  const args = ["c", "-r", "--hints:off", "--warnings:off", `--path:${root}`, `--nimcache:${cache}`, `--out:${binary}`];
  if (process.platform === "win32") args.push("--cc:clang");
  args.push(file);
  const started = performance.now();
  const environment = { ...process.env, TEMP: temp, TMP: temp, TMPDIR: temp,
    FOOTESTID: `${run}-${id}` };
  return new Promise(resolveResult => {
    const child = spawn(compiler, args, { cwd: root, env: environment,
      windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let failure;
    let timedOut = false;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", error => { failure = error.message; });
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill();
    }, timeout);
    child.on("close", code => {
      clearTimeout(timer);
      const error = timedOut ? `Timed out after ${timeout} ms` : failure;
      resolveResult({ file: name, passed: code === 0 && !error, code,
        elapsed: performance.now() - started, stdout, stderr, error });
    });
  });
}

let next = 0;
async function worker() {
  while (next < files.length) {
    const index = next++;
    const result = await execute(files[index]);
    results[index] = result;
    console.log(`${result.passed ? "PASS" : "FAIL"} ${result.file} (${Math.round(result.elapsed)} ms)`);
    if (!result.passed)
      process.stderr.write(result.stderr || result.stdout || result.error || "Unknown native test failure\n");
  }
}
await Promise.all(Array.from({ length: jobs }, () => worker()));

const report = JSON.stringify(results, null, 2) + "\n";
writeFileSync(join(output, "results.json"), report);
writeFileSync(join(base, "results.json"), report);
console.log(`${results.filter(result => result.passed).length}/${results.length} native tests passed.`);
if (results.some(result => !result.passed)) process.exitCode = 1;
