import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { arch, cpus, platform, release, totalmem } from "node:os";
import { dirname, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { detect } from "./toolchain.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const packageInfo = JSON.parse(readFileSync(resolve(root, "package.json"), "utf8"));
const catalog = JSON.parse(readFileSync(resolve(root, "benchmark", "catalog.json"), "utf8"));

function option(name) {
  const index = process.argv.indexOf(name);
  if (index < 0) return "";
  const result = process.argv[index + 1];
  if (!result || result.startsWith("--")) throw Error(`${name} requires a value`);
  return result;
}
function count(name, fallback, minimum) {
  const source = option(name);
  if (!source) return fallback;
  const result = Number(source);
  if (!Number.isInteger(result) || result < minimum) throw Error(`${name} must be an integer of at least ${minimum}`);
  return result;
}
function summary(samples) {
  const ordered = [...samples].sort((a, b) => a - b);
  const middle = Math.floor(ordered.length / 2);
  const median = ordered.length % 2 ? ordered[middle] : (ordered[middle - 1] + ordered[middle]) / 2;
  return {
    minimumMs: ordered[0], medianMs: median,
    meanMs: ordered.reduce((sum, item) => sum + item, 0) / ordered.length,
    percentile95Ms: ordered[Math.max(0, Math.ceil(ordered.length * 0.95) - 1)],
    maximumMs: ordered.at(-1), samplesMs: samples,
  };
}
function metrics(output) {
  const line = output.split(/\r?\n/).find(item => item.startsWith("FOO_METRICS "));
  return line ? JSON.parse(line.slice(12)) : {};
}
function execute(command, args, settings = {}) {
  const result = spawnSync(command, args, {
    cwd: root, encoding: "utf8", maxBuffer: 32 * 1024 * 1024,
    windowsHide: true, ...settings,
  });
  if (result.error || result.status !== 0) throw Error(result.error?.message || result.stderr || result.stdout || `${command} failed`);
  return result;
}

if (process.argv.includes("--help")) {
  console.log("Usage: node tools/benchmark.mjs [--backend c|zig] [--mode dev|release] [--warmup N] [--iterations N] [--output FILE]");
  console.log("Measures FOO and handwritten C, Zig, and Rust controls, keeping raw samples and startup baselines.");
  process.exit(0);
}

const warmup = count("--warmup", 3, 0);
const iterations = count("--iterations", 20, 1);
const baselineWarmup = Math.max(warmup, 5);
const baselineIterations = Math.max(iterations, 21);
const selectedBackend = option("--backend");
const selectedMode = option("--mode");
if (selectedBackend && !["c", "zig"].includes(selectedBackend)) throw Error("--backend must be c or zig");
if (selectedMode && !["dev", "release"].includes(selectedMode)) throw Error("--mode must be dev or release");
const backends = selectedBackend ? [selectedBackend] : ["c", "zig"];
const modes = selectedMode ? [selectedMode] : ["dev", "release"];
const expected = Object.keys(catalog).sort();
const measured = new Map(expected.map(name => [name, []]));

function sample(command, args, warmupCount, iterationCount) {
  for (let index = 0; index < warmupCount; index++) execute(command, args);
  const samples = [];
  let allocation = {};
  for (let index = 0; index < iterationCount; index++) {
    const started = performance.now();
    const run = execute(command, args);
    samples.push(performance.now() - started);
    allocation = metrics(run.stderr + run.stdout);
  }
  return { ...summary(samples), allocation };
}

function foo(backend, mode) {
  const run = execute(process.execPath, [resolve(root, "bin", "foo.mjs"), "benchmark",
    "--backend", backend, "--mode", mode, "--warmup", String(warmup),
    "--iterations", String(iterations), "--json"]);
  const records = run.stdout.split(/\r?\n/).filter(Boolean).map(line => {
    try { return JSON.parse(line); } catch { return null; }
  }).filter(Boolean);
  const events = records.filter(item => item.event === "benchmark");
  const artifact = records.filter(item => item.event === "done" && item.file).at(-1)?.file;
  const names = events.map(item => item.name).sort();
  if (JSON.stringify(names) !== JSON.stringify(expected)) throw Error(`Expected ${expected.join(", ")}; received ${names.join(", ")} for FOO/${backend}/${mode}`);
  for (const event of events) {
    let result = {
      implementation: "foo", backend, mode,
      minimumMs: event.minimumMs, medianMs: event.medianMs,
      meanMs: event.meanMs, percentile95Ms: event.percentile95Ms,
      maximumMs: event.maximumMs, samplesMs: event.samplesMs,
      compilationMs: event.compilationMs, compilationCached: event.cached,
      allocation: event.metrics || {}, optimization: event.optimization || {},
    };
    if (event.name === "startup") {
      if (!artifact) throw Error(`Missing startup artifact for FOO/${backend}/${mode}`);
      const stable = sample(artifact, [], baselineWarmup, baselineIterations);
      result = { ...result, ...stable, baselineResampled: true };
    }
    measured.get(event.name).push(result);
    console.log(`${event.name.padEnd(12)} foo/${backend.padEnd(3)} ${mode.padEnd(7)} median ${result.medianMs.toFixed(2)} ms`);
  }
}

function compileNative(backend, mode) {
  const directory = resolve(root, ".artifacts", "benchmark", backend, mode);
  mkdirSync(directory, { recursive: true });
  const suffix = process.platform === "win32" ? ".exe" : "";
  const artifact = resolve(directory, `native-${backend}${suffix}`);
  const started = performance.now();
  if (backend === "c") {
    execute(process.env.CC || "clang", ["-std=c11", mode === "release" ? "-O2" : "-O0", "-g",
      resolve(root, "benchmark", "native.c"), "-o", artifact]);
  } else if (backend === "zig") {
    const zig = detect();
    if (!zig) throw Error("Managed Zig toolchain is missing; run foo toolchain install");
    execute(zig.path, ["build-exe", resolve(root, "benchmark", "native.zig"),
      "-O", mode === "release" ? "ReleaseSafe" : "Debug",
      "--cache-dir", resolve(directory, "cache"), "-femit-bin=" + artifact]);
  } else {
    const rust = process.env.RUSTC || "rustc";
    execute(rust, ["--edition=2024", "-C", mode === "release" ? "opt-level=3" : "opt-level=0",
      ...(mode === "release" ? [] : ["-C", "debuginfo=2"]),
      resolve(root, "benchmark", "native.rs"), "-o", artifact]);
  }
  return { artifact, compilationMs: performance.now() - started };
}

function native(backend, mode) {
  const built = compileNative(backend, mode);
  for (const name of expected) {
    const inputs = [name, String(cpus().length)];
    const startup = name === "startup";
    const sampled = sample(built.artifact, inputs,
      startup ? baselineWarmup : warmup,
      startup ? baselineIterations : iterations);
    const result = {
      implementation: "native", backend, mode, ...sampled,
      compilationMs: built.compilationMs, compilationCached: false,
      compilationShared: true, baselineResampled: startup,
      optimization: { compilerControlled: true },
    };
    measured.get(name).push(result);
    console.log(`${name.padEnd(12)} native/${backend.padEnd(3)} ${mode.padEnd(7)} median ${result.medianMs.toFixed(2)} ms`);
  }
}

for (const mode of modes) {
  for (const backend of backends) foo(backend, mode);
  for (const backend of ["c", "zig", "rust"]) native(backend, mode);
}

for (const mode of modes) for (const backend of new Set([...backends, "c", "zig", "rust"])) {
  for (const implementation of ["foo", "native"]) {
    const baseline = measured.get("startup").find(item => item.mode === mode && item.backend === backend && item.implementation === implementation);
    const runtime = measured.get("runtime").find(item => item.mode === mode && item.backend === backend && item.implementation === implementation);
    if (!baseline || !runtime) continue;
    for (const results of measured.values()) for (const result of results) {
      if (result.mode === mode && result.backend === backend && result.implementation === implementation) {
      result.startupBaselineMs = baseline.medianMs;
      result.runtimeBaselineMs = runtime.medianMs;
      result.startupAdjustedMedianMs = Math.max(0, result.medianMs - baseline.medianMs);
      result.runtimeAdjustedMedianMs = Math.max(0, result.medianMs - runtime.medianMs);
      }
    }
  }
}

for (const results of measured.values()) {
  for (const result of results.filter(item => item.implementation === "foo")) {
    const rust = results.find(item => item.implementation === "native" &&
      item.backend === "rust" && item.mode === result.mode);
    if (!rust) continue;
    result.rustMedianMs = rust.medianMs;
    result.speedupAgainstRust = rust.medianMs / result.medianMs;
    result.fasterThanRust = result.medianMs < rust.medianMs;
  }
}

const processors = cpus();
const report = {
  schema: "foo.benchmark/v4", measuredAt: new Date().toISOString(),
  compiler: packageInfo.version, warmup, iterations,
  baselineWarmup, baselineIterations,
  caution: "Startup-adjusted values and speed ratios are estimates. Compare raw samples and allocation/optimization evidence before attributing a difference to FOO. A workload result is not a language-wide speed claim.",
  machine: {
    platform: `${platform()} ${release()}`, architecture: arch(),
    processor: processors[0]?.model ?? "unknown", logicalCores: processors.length,
    memoryGiB: Number((totalmem() / 1024 ** 3).toFixed(1)),
  },
  workloads: expected.map(name => ({
    name, file: `benchmark/${name}.iv`, purpose: catalog[name].purpose,
    work: catalog[name].work, results: measured.get(name),
  })),
};
const output = resolve(option("--output") || resolve(root, "benchmark", "results.json"));
writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
console.log(`Wrote ${output}`);
