// Run real providers and retain evidence. This never enables I/O batching.
import { spawn, spawnSync } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const windows = process.platform === "win32";
const compiler = resolve(process.env.FOO_COMPILER || join(root, ".artifacts/native", windows ? "foo.exe" : "foo"));
const directory = join(root, ".artifacts", "llvm-runtime-acceptance");
mkdirSync(directory, { recursive: true });
if (!existsSync(compiler)) throw Error("Build FOO first: node tools/native.mjs --mm refc");
const report = { format: "foo.llvm.runtime.acceptance.v1", passed: false,
  host: `${process.platform}-${process.arch}`, compiler, checks: [],
  ioBatching: { enabled: false, reason: "Existing stream writes flush individually; no coalescing proof or qualified threshold." } };
function save() {
  writeFileSync(join(directory, "acceptance.json"), JSON.stringify(report, null, 2) + "\n");
}
save();
async function run(name, command, args, env = {}) {
  console.log(`Checking ${name}`);
  let output = "";
  const milliseconds = Number(process.env.FOO_RUNTIME_TEST_TIMEOUT || 1800000);
  if (!Number.isFinite(milliseconds) || milliseconds <= 0)
    throw Error("FOO_RUNTIME_TEST_TIMEOUT must be a positive number of milliseconds");
  const log = join(directory, `${name}.log`);
  writeFileSync(log, "");
  const code = await new Promise((done, fail) => {
    const child = spawn(command, args, { cwd: root, windowsHide: true,
      detached: !windows, env: { ...process.env, FOO_COMPILER: compiler, FOO_TEST_COMPILER: compiler,
        FOO_IO_BATCHING: "off", ...env }, stdio: ["ignore", "pipe", "pipe"] });
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      appendFileSync(log, `\nAcceptance command timed out after ${milliseconds} ms\n`);
      if (windows) spawnSync("taskkill", ["/pid", String(child.pid), "/t", "/f"],
        { windowsHide: true, stdio: "ignore" });
      else { try { process.kill(-child.pid, "SIGKILL"); } catch { child.kill("SIGKILL"); } }
    }, milliseconds);
    for (const stream of [child.stdout, child.stderr])
      stream.on("data", data => { output += data; appendFileSync(log, data); });
    child.once("error", error => { clearTimeout(timer); fail(error); });
    child.once("close", code => { clearTimeout(timer); done(timedOut ? 124 : code); });
  });

  const checked = { name, passed: code === 0, code, log };
  report.checks.push(checked);
  save();
  if (code !== 0) throw Error(`${name} failed (${code}); see ${log}`);
  return { checked, output };
}

// Force dynamic-library tests to execute rather than taking their optional path.
const source = join(directory, "increment.c");
const library = join(directory, windows ? "increment.dll" : "increment.so");
writeFileSync(source, "#include <stdint.h>\n#ifdef _WIN32\n__declspec(dllexport)\n#endif\nuint64_t increment(uint64_t value) { return value + 1; }\n");
await run("dynamic-library-fixture", "clang", ["-shared", ...(windows ? [] : ["-fPIC"]), source, "-o", library]);
for (const backend of ["c", "zig", "llvm"]) {
  const { checked, output } = await run(`library-${backend}`, compiler,
    ["test", "test/library", "--backend", backend, "--json", "--no-batching"],
    { FOO_DYLIB_TEST_PATH: library });
  const events = output.split(/\r?\n/).filter(line => line.startsWith("{")).map(line => JSON.parse(line));
  const complete = events.findLast(event => event.event === "complete");
  if (!complete?.success) throw Error(`Missing successful test summary: ${backend}`);
  checked.summary = complete.summary;
  const executions = events.filter(event => event.event === "run");
  if (!executions.length) throw Error(`No generated artifacts executed: ${backend}`);
  checked.executions = executions.length;
  if (backend === "llvm") {
    for (const execution of executions) {
      const artifact = execution.file;
      const generated = dirname(artifact);
      const identity = JSON.parse(readFileSync(join(generated, "llvm.json"), "utf8"));
      if (identity.backend !== "llvm" || identity.runtimeAbi !== "foo.runtime.pointer.v1")
        throw Error(`Wrong backend/runtime identity: ${generated}`);
      if (!readFileSync(join(generated, "main.ll"), "utf8").includes("; FOO LLVM backend") ||
          !existsSync(join(generated, "verified.ll")) ||
          !readFileSync(join(generated, "verify.diagnostics"), "utf8").includes("exitCode=0"))
        throw Error(`Missing verified LLVM artifact: ${generated}`);
      const effects = JSON.parse(readFileSync(join(generated, "io-batches.json"), "utf8"));
      if (effects.enabled || effects.formedBatches !== 0)
        throw Error(`Unqualified batching was enabled: ${generated}`);
    }
    checked.verifiedArtifacts = executions.length;
  }
  save();
}
await run("tls-llvm", process.execPath, ["test/library/tls.mjs", "--backend=llvm"]);
// This includes aggregate FFI, source/result slots, io_uring failure injection,
// SPIR-V/Vulkan execution, naked startup/interrupts and legacy backend gates.
await run("native", process.execPath, ["test/native/run.mjs", "--jobs=2"]);
report.passed = true;
save();
console.log(`Runtime acceptance passed; evidence: ${join(directory, "acceptance.json")}`);
