import { find } from '../../tools/nim.mjs';
import { existsSync as exists, mkdirSync as mkdir, readFileSync as read, writeFileSync } from "node:fs";
import { availableParallelism as concurrency, totalmem } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { spawn, spawnSync as invoke } from "node:child_process";
import { fileURLToPath as filename } from "node:url";
import { plan, prepare } from "./plan.mjs";
import { progress } from "./events.mjs";
import { environment, temporary as testOutput } from '../location.mjs';

const root = resolve(dirname(filename(import.meta.url)), "../..");
const compiler = find();
const unbatched = process.argv.includes("--no-batching") || process.env.FOO_TEST_NO_BATCHING === "1";
const filter = process.argv.find(a => a.startsWith("--filter="))?.slice(9) || "";
const selection = process.argv.find(a => a.startsWith('--selection='))?.slice(12);
const ids = selection ? new Set(JSON.parse(read(selection, 'utf8')).ids) : null;
const { units, groupedModules: grouped } = plan(root,
  { noBatching: unbatched, filter, ids });
const files = units.map(unit => unit.file);
if(files.length===0) throw Error("No native suites selected");
if (process.argv.includes("--list")) {
  console.log(JSON.stringify({ compileUnits: units.length, modules: units.flatMap(unit => unit.modules),
    units: units.map(({name, modules}) => ({name, modules})) }, null, 2));
  process.exit(0);
}
const indexed = files.map((file, index) => ({ file, index }));
const parallel = indexed;
const run = `run-${process.pid}-${Date.now()}`;
const output = resolve(process.argv.find(a=>a.startsWith("--output="))?.slice(9) || testOutput());
mkdir(output, { recursive: true });
const selected = process.argv.find(argument => argument.startsWith("--jobs="))?.slice(7)
  ?? process.env.FOO_TEST_JOBS;
const requested = Number.parseInt(selected ?? "", 10);
const capacity = Math.max(1, Math.floor(totalmem() / (3 * 1024 ** 3)));
const automatic = Math.min(4, Math.max(1, concurrency() - 1), capacity);
const jobs = Math.min(files.length, 4, capacity, Math.max(1, concurrency() - 1),
  Number.isFinite(requested) && requested > 0 ? requested : automatic);
const deadline = Number.parseInt(process.env.FOO_TEST_TIMEOUT ?? "", 10);
const timeout = Number.isFinite(deadline) && deadline > 0
  ? deadline : 3600000;
const results = [];

console.log(`Running ${files.length} native suites (${grouped} modules grouped) with ${jobs} jobs.`);

function execute(file) {
  const name = relative(join(root, "test"), file).replaceAll("\\", "/");
  const id = name.replace(/\.nim$/, "").replaceAll("/", "-");
  const binary = join(output, id + (process.platform === "win32" ? ".exe" : ""));
  const cache = join(output, "cache", id);
  const work = join(output, 'work', id);
  const unit = units.find(unit => unit.file === file);
  const modules = unit.modules;
  const source = prepare(unit, output);
  mkdir(cache, { recursive: true });
  mkdir(work, { recursive: true });
  const args = ["c", "--hints:off", "--warnings:off", `--path:${root}`, `--nimcache:${cache}`, `--out:${binary}`];
  args.push("-d:release", "--opt:size", "--mm:refc", "--parallelBuild:1");
  if (process.platform === "win32") args.push("--cc:clang");
  args.push(source);
  const duration = timeout;
  const started = performance.now();
  const runtime = environment(work, { ...process.env,
    FOOTESTID: `${run}-${id}` });
  return new Promise(done => {
    let stdout = "";
    let stderr = "";
    let failure;
    let expired = false;
    let active;
    let executed = false;
    let compilation = 0;
    let execution = 0;
    const completed = new Set();
    const event = progress(runtime.FOOTESTID, modules, completed);
    let buffer = '';
    let timer;
    function stop() {
      clearTimeout(timer);
      if (active?.pid) {
        if (process.platform === "win32") invoke("taskkill", ["/pid", String(active.pid), "/t", "/f"], { windowsHide: true, stdio: "ignore" });
        else try { process.kill(-active.pid, "SIGKILL"); } catch {}
      }
    }
    function watchdog() {
      clearTimeout(timer);
      timer = setTimeout(() => {
        expired = true;
        stop();
      }, duration);
    }
    watchdog();
    function finish(code) {
      clearTimeout(timer);
      const error = expired ? `Timed out after ${duration} ms without compilation, module or case completion` : failure ||
        (executed && code === 0 && modules.length > 1 && completed.size !== modules.length ? 'Missing counted module completions' : undefined);
      done({ file: name, modules, completedModules: [...completed],
        executedModules: modules.length > 1 ? completed.size : Number(executed),
        moduleCountExact: !executed || modules.length === 1 || code === 0 && !error,
        passedModules: modules.length > 1 ? completed.size : Number(executed && code === 0 && !error), executed, passed: code === 0 && !error, code,
        elapsed: performance.now() - started, compileMs: compilation || performance.now() - started,
        runMs: execution ? performance.now() - execution : 0, stdout, stderr, error });
    }
    function launch(command, parameters, next) {
      const child = spawn(command, parameters, { cwd: root, env: runtime,
        windowsHide: true, detached: process.platform!=="win32", stdio: ["ignore", "pipe", "pipe"] });
      active = child;
      if (command === binary) child.once('spawn', () => {
        executed = true; execution = performance.now();
        watchdog();
      });
      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      function capture(stream, chunk) {
        if (stdout.length + stderr.length + chunk.length > 32 * 1024 * 1024) {
          failure = "Native suite output limit exceeded";
          stop();
        } else if(stream === "stdout") {
          stdout += chunk;
          if (executed) {
            buffer += chunk;
            let newline;
            while ((newline = buffer.indexOf('\n')) >= 0) {
              const line = buffer.slice(0, newline).replace(/\r$/, '');
              buffer = buffer.slice(newline + 1);
              try { if (!failure && event(line)) watchdog(); }
              catch (error) { failure = error.message; stop(); }
            }
          }
        }
        else stderr += chunk;
      }
      child.stdout.on("data", chunk => capture("stdout", chunk));
      child.stderr.on("data", chunk => capture("stderr", chunk));
      child.on("error", error => { failure = error.message; });
      child.on("close", code => {
        if (expired || failure || code !== 0 || !next) finish(code);
        else next();
      });
    }
    launch(compiler, args, () => { compilation = performance.now() - started; launch(binary, [], null); });
  });
}

function save(complete=false) {
  const observed=results.filter(Boolean);
  const count=observed.reduce((n,r)=>n+r.executedModules,0);
  writeFileSync(join(output,"summary.json"),JSON.stringify({format:"foo.native-tests.v3",fullSuite:!filter&&!ids,noBatching: unbatched,complete,passed:complete&&observed.length===files.length&&observed.every(r=>r.passed),expectedSuites:files.length,observedSuites:observed.length,executedSuites:observed.filter(r=>r.executed).length,executedModules: count,partialSuites:observed.filter(r=>!r.moduleCountExact).length,passedModules:observed.reduce((n,r)=>n+r.passedModules,0),results:observed},null,2)+"\n");
}
save();
function record(result, index) {
  results[index] = result;
  save();
  console.log(`${result.passed ? "PASS" : "FAIL"} ${result.file} (${Math.round(result.elapsed)} ms)`);
  if (!result.passed) {
    if (result.error) process.stderr.write(result.error + "\n");
    process.stderr.write(result.stderr || result.stdout || "Unknown native test failure\n");
  }
}
let next = 0;
async function worker() {
  while (next < parallel.length) {
    const { file, index } = parallel[next++];
    const result = await execute(file);
    record(result, index);
  }
}
await Promise.all(Array.from({ length: jobs }, () => worker()));

const report = JSON.stringify(results, null, 2) + "\n";
writeFileSync(join(output, "results.json"), report);
const count=results.reduce((n,r)=>n+r.executedModules,0);
save(true);
console.log(`${count} test modules executed; ${results.filter(r=>r.executed).length}/${files.length} suites executed.`);
console.log(`${results.filter(result => result.passed).length}/${results.length} native tests passed.`);
if (results.some(result => !result.passed)) process.exitCode = 1;
