import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
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
const suites = ["syntax", "engine", "build", "cli", "package"]
  .map(name => join(root, "test", "suites", `${name}.nim`));
const grouped = new Set();
for (const suite of suites) {
  const source = readFileSync(suite, "utf8");
  for (const match of source.matchAll(/^import \.\.\/([a-z/]+) as [a-z]+$/gm)) {
    const file = join(root, "test", `${match[1]}.nim`);
    if (!existsSync(file) || grouped.has(file)) throw Error(`Invalid suite import: ${file}`);
    grouped.add(file);
  }
}
const files = readdirSync(join(root, "test"), { recursive: true, withFileTypes: true })
  .filter(entry => entry.isFile() && entry.name.endsWith(".nim"))
  .map(entry => join(entry.parentPath, entry.name))
  .filter(file => !grouped.has(file))
  .sort();
const serial = new Set(["backend/c/threads.nim", "backend/c/wasi.nim"]);
const indexed = files.map((file, index) => ({ file, index }));
const parallel = indexed.filter(({ file }) => !serial.has(relative(join(root, "test"), file).replaceAll("\\", "/")));
const isolated = indexed.filter(({ file }) => serial.has(relative(join(root, "test"), file).replaceAll("\\", "/")));
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
  ? selectedTimeout : 600000;
const results = [];

console.log(`Running ${files.length} native suites (${grouped.size} modules grouped) with ${jobs} jobs.`);

function execute(file) {
  const name = relative(join(root, "test"), file).replaceAll("\\", "/");
  const id = name.replace(/\.nim$/, "").replaceAll("/", "-");
  const binary = join(output, id + (process.platform === "win32" ? ".exe" : ""));
  const cache = join(output, "cache", id);
  const temp = join(temporary, id);
  mkdirSync(cache, { recursive: true });
  mkdirSync(temp, { recursive: true });
  const args = ["c", "--hints:off", "--warnings:off", `--path:${root}`, `--nimcache:${cache}`, `--out:${binary}`];
  if (process.platform === "win32") args.push("--cc:clang");
  args.push(file);
  const started = performance.now();
  const environment = { ...process.env, TEMP: temp, TMP: temp, TMPDIR: temp,
    FOOTESTID: `${run}-${id}` };
  return new Promise(resolveResult => {
    let stdout = "";
    let stderr = "";
    let failure;
    let timedOut = false;
    let active;
    const timer = setTimeout(() => {
      timedOut = true;
      active?.kill();
    }, timeout);
    function finish(code) {
      clearTimeout(timer);
      const error = timedOut ? `Timed out after ${timeout} ms` : failure;
      resolveResult({ file: name, passed: code === 0 && !error, code,
        elapsed: performance.now() - started, stdout, stderr, error });
    }
    function launch(command, parameters, next) {
      const child = spawn(command, parameters, { cwd: root, env: environment,
        windowsHide: true, stdio: ["ignore", "pipe", "pipe"] });
      active = child;
      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", chunk => { stdout += chunk; });
      child.stderr.on("data", chunk => { stderr += chunk; });
      child.on("error", error => { failure = error.message; });
      child.on("close", code => {
        if (timedOut || failure || code !== 0 || !next) finish(code);
        else next();
      });
    }
    launch(compiler, args, () => launch(binary, [], null));
  });
}

let next = 0;
async function worker() {
  while (next < parallel.length) {
    const { file, index } = parallel[next++];
    const result = await execute(file);
    results[index] = result;
    console.log(`${result.passed ? "PASS" : "FAIL"} ${result.file} (${Math.round(result.elapsed)} ms)`);
    if (!result.passed)
      process.stderr.write(result.stderr || result.stdout || result.error || "Unknown native test failure\n");
  }
}
await Promise.all(Array.from({ length: jobs }, () => worker()));
for (const { file, index } of isolated) {
  const result = await execute(file);
  results[index] = result;
  console.log(`${result.passed ? "PASS" : "FAIL"} ${result.file} (${Math.round(result.elapsed)} ms)`);
  if (!result.passed)
    process.stderr.write(result.stderr || result.stdout || result.error || "Unknown native test failure\n");
}

const report = JSON.stringify(results, null, 2) + "\n";
writeFileSync(join(output, "results.json"), report);
writeFileSync(join(base, "results.json"), report);
console.log(`${results.filter(result => result.passed).length}/${results.length} native tests passed.`);
if (results.some(result => !result.passed)) process.exitCode = 1;
