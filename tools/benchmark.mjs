import { summary } from './statistics.mjs';
import { value as option } from './arguments.mjs';
import { copyFileSync as copy, existsSync as exists, mkdirSync as mkdir, readFileSync as read, writeFileSync as write } from "node:fs";
import { arch, cpus, platform, release, totalmem } from "node:os";
import { dirname, join, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { spawnSync as invoke } from "node:child_process";
import { createHash } from "node:crypto";
import { fileURLToPath as filename } from "node:url";
import { detect } from "./toolchain.mjs";
import * as artifacts from './artifacts.mjs';

const root = resolve(dirname(filename(import.meta.url)), "..");
const manifest = JSON.parse(read(resolve(root, "package.json"), "utf8"));
const catalog = JSON.parse(read(resolve(root, "benchmark", "catalog.json"), "utf8"));

function count(name, fallback, minimum) {
  const source = option(name);
  if (!source) return fallback;
  const result = Number(source);
  if (!Number.isInteger(result) || result < minimum) throw Error(`${name} must be an integer of at least ${minimum}`);
  return result;
}
function metrics(output) {
  const line = output.split(/\r?\n/).find(item => item.startsWith("FOO_METRICS "));
  return line ? JSON.parse(line.slice(12)) : {};
}
function budget(name, label, samples) {
  const budget = catalog[name].metricBudget;
  if (!budget) return;
  if (samples.length === 0)
    throw Error(`${name} ${label}: missing timed metric samples`);
  for (const [index, sample] of samples.entries()) {
    for (const [metric, maximum] of Object.entries(budget)) {
      const actual = sample[metric];
      if (!Number.isFinite(actual) || actual < 0 || actual > maximum)
        throw Error(`${name} ${label} sample ${index + 1}: ${metric}=${actual ?? "missing"} exceeds budget ${maximum}`);
    }
  }
}
function execute(command, args, settings = {}) {
  const result = invoke(command, args, {
    cwd: root, encoding: "utf8", maxBuffer: 32 * 1024 * 1024,
    windowsHide: true, ...settings,
  });
  if (result.error || result.status !== 0) throw Error(result.error?.message || result.stderr || result.stdout || `${command} failed`);
  return result;
}
function inspect(artifact, label) {
  const manifest = label.startsWith("foo/") ? JSON.parse(read(`${artifact}.qbe.json`, "utf8")) : null;
  const binary = read(artifact);
  let format = '', architecture = '';
  if (binary.length >= 64 && binary.toString('ascii', 0, 2) === 'MZ') {
    const offset = binary.readUInt32LE(0x3c);
    if (offset + 6 <= binary.length && binary.toString('ascii', offset, offset + 4) === 'PE\0\0') {
      format = 'PE';
      architecture = ({ 0x8664: 'x64', 0xaa64: 'arm64' })[binary.readUInt16LE(offset + 4)] || '';
    }
  } else if (binary.length >= 20 && binary.toString('binary', 0, 4) === '\x7fELF') {
    format = 'ELF';
    architecture = ({ 0x3e: 'x64', 0xb7: 'arm64', 0xf3: 'riscv64' })[binary.readUInt16LE(18)] || '';
  } else if (binary.length >= 8 && binary.toString('binary', 0, 4) === '\0asm') {
    format = 'WASM'; architecture = 'wasm32';
  }
  if (!format || !architecture) throw Error(`${label}: invalid executable header: ${artifact}`);
  const directory = resolve(benchmarkRun, "binary", ...label.split("/"));
  mkdir(directory, { recursive: true });
  const preserved = resolve(directory, process.platform === "win32" ? "program.exe" : "program");
  copy(artifact, preserved);
  return {
    artifact: preserved, format, architecture, bytes: binary.length,
    sha256: createHash("sha256").update(binary).digest("hex"),
    ...(manifest ? { policy: manifest.policy, target: manifest.target,
      nativeInputsSha256: manifest.nativeInputsSha256,
      qbeSha256: manifest.qbe?.sha256, ccSha256: manifest.cc?.sha256 } : {}),
  };
}

if (process.argv.includes("--help")) {
  console.log("Usage: node tools/benchmark.mjs [--compiler FILE] [--workload NAME] [--backend qbe] [--reference-controls c,cpp,rust,zig] [--mode dev|release] [--warmup N] [--iterations N] [--output FILE]");
  console.log("Measures QBE FOO against native controls; reports and binary copies stay in an isolated .artifacts/bench run.");
  process.exit(0);
}

const warmup = count("--warmup", 3, 0);
const iterations = count("--iterations", 20, 1);
const priming = Math.max(warmup, 5);
const repetitions = Math.max(iterations, 21);
const selection = option("--backend");
const pipeline = option("--mode");
const workload = option("--workload");
const compilerPath = option("--compiler");
if (selection && selection !== "qbe") throw Error("FOO benchmarks execute QBE; use --reference-controls for native controls");
const controls = (option("--reference-controls") || "c,cpp,rust,zig").split(",").filter(Boolean);
if (controls.some(c=>!["c","cpp","rust","zig"].includes(c))||new Set(controls).size!==controls.length) throw Error("Invalid reference controls; choose unique c,cpp,rust,zig values");
if (pipeline && !["dev", "release"].includes(pipeline)) throw Error("--mode must be dev or release");
if (workload && !Object.hasOwn(catalog, workload))
  throw Error(`Unknown benchmark workload: ${workload}`);
const benchmarkRun = artifacts.create('bench');
const backends = ["qbe"];
const modes = pipeline ? [pipeline] : ["dev", "release"];
const expected = workload ? [workload] : Object.keys(catalog).sort();
const measured = new Map(expected.map(name => [name, []]));
function checkpoint() {
  write(resolve(benchmarkRun, "progress.json"), JSON.stringify({
    selection: workload || "all", modes, referenceControls: controls,
    workloads: Object.fromEntries(measured),
  }, null, 2) + "\n");
}

function sample(command, args, priming, repetitions) {
  for (let index = 0; index < priming; index++) execute(command, args);
  const samples = [];
  const allocations = [];
  for (let index = 0; index < repetitions; index++) {
    const started = performance.now();
    const run = execute(command, args);
    samples.push(performance.now() - started);
    allocations.push(metrics(run.stderr + run.stdout));
  }
  return { ...summary(samples), allocation: allocations.at(-1), allocationSamples: allocations };
}

function foo(backend, mode) {
  for (const name of expected) {
    const run = execute(process.execPath, [resolve(root, "bin", "foo.mjs"), "benchmark",
      `benchmark/workloads/${name}.iv`, "--backend", backend, "--mode", mode,
      "--warmup", "0", "--iterations", "1", "--json"],
      compilerPath ? { env: { ...process.env, FOO_COMPILER: compilerPath } } : {});
    const records = run.stdout.split(/\r?\n/).filter(Boolean).map(line => {
      try { return JSON.parse(line); } catch { return null; }
    }).filter(Boolean);
    const events = records.filter(item => item.event === "benchmark");
    const artifact = records.filter(item => item.event === "done" && item.file).at(-1)?.file;
    if (events.length !== 1 || events[0].name !== name)
      throw Error(`Expected ${name}; received ${events.map(item => item.name).join(", ")} for FOO/${backend}/${mode}`);
    const event = events[0];
    if (!artifact) throw Error(`Missing executable artifact for FOO/${backend}/${mode}/${name}`);
    let result = {
      implementation: "foo", backend, mode,
      minimumMs: event.minimumMs, medianMs: event.medianMs,
      meanMs: event.meanMs, percentile95Ms: event.percentile95Ms,
      maximumMs: event.maximumMs, samplesMs: event.samplesMs,
      compilationMs: event.compilationMs, compilationCached: event.cached,
      allocation: event.metrics || {}, optimization: event.optimization || {},
      allocationSamples: event.metricsSamples || [],
      binary: inspect(artifact, `foo/${backend}/${mode}/${name}`),
    };
    budget(event.name, `foo/${backend}/${mode}`, result.allocationSamples);
    measured.get(event.name).push(result);
    checkpoint();
    console.log(`${event.name.padEnd(12)} foo/${backend.padEnd(3)} ${mode.padEnd(7)} median ${result.medianMs.toFixed(2)} ms`);
  }
}

function compile(backend, mode) {
  const directory = resolve(benchmarkRun, backend, mode);
  mkdir(directory, { recursive: true });
  const suffix = process.platform === "win32" ? ".exe" : "";
  const artifact = resolve(directory, `native-${backend}${suffix}`);
  const started = performance.now();
  let compiler, source, flags, sourceFiles;
  if (backend === "c") {
    compiler = process.env.CC || "clang";
    source = resolve(root, "benchmark", "controls", "c", "native.c");
    sourceFiles = [source];
    flags = ["-std=c11", mode === "release" ? "-O2" : "-O0", "-g"];
    execute(compiler, [...flags, source, "-o", artifact]);
  } else if (backend === "cpp") {
    compiler = process.env.CXX || "clang++";
    source = resolve(root, "benchmark", "controls", "c", "native.cpp");
    sourceFiles = [resolve(root, "benchmark", "controls", "c", "native.c"), source];
    flags = ["-std=c++20", mode === "release" ? "-O2" : "-O0", "-g",
      ...(process.platform === "win32" ? ["-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH"] : [])];
    execute(compiler, [...flags, source, "-o", artifact]);
  } else if (backend === "zig") {
    const zig = detect();
    if (!zig) throw Error("Zig reference control is missing; run node tools/toolchain.mjs explicitly");
    compiler = zig.path;
    source = resolve(root, "benchmark", "controls", "zig", "native.zig");
    sourceFiles = [source];
    flags = ["-O", mode === "release" ? "ReleaseSafe" : "Debug"];
    execute(compiler, ["build-exe", source, ...flags,
      "--cache-dir", resolve(directory, "cache"), "-femit-bin=" + artifact]);
  } else {
    compiler = process.env.RUSTC || "rustc";
    source = resolve(root, "benchmark", "controls", "rust", "native.rs");
    sourceFiles = [source];
    flags = ["--edition=2024", "-C", mode === "release" ? "opt-level=3" : "opt-level=0",
      ...(mode === "release" ? [] : ["-C", "debuginfo=2"] )];
    execute(compiler, [...flags, source, "-o", artifact]);
  }
  return { artifact, compilationMs: performance.now() - started,
    binary: inspect(artifact, `native/${backend}/${mode}`),
    compiler: { command: compiler, version: execute(compiler,
      [backend === "zig" ? "version" : "--version"]).stdout.trim().split(/\r?\n/)[0],
      flags, sourceSha256: createHash("sha256").update(Buffer.concat(sourceFiles.map(file => read(file)))).digest("hex") } };
}

function native(backend, mode) {
  const built = compile(backend, mode);
  for (const name of expected) {
    const inputs = [name, String(cpus().length)];
    const sampled = sample(built.artifact, inputs, 0, 1);
    const result = {
      implementation: "native", backend, mode, ...sampled,
      compilationMs: built.compilationMs, compilationCached: false,
      compilationShared: true,
      optimization: { compilerControlled: true },
      binary: built.binary,
      compiler: built.compiler,
    };
    budget(name, `native/${backend}/${mode}`, result.allocationSamples);
    measured.get(name).push(result);
    checkpoint();
    console.log(`${name.padEnd(12)} native/${backend.padEnd(3)} ${mode.padEnd(7)} median ${result.medianMs.toFixed(2)} ms`);
  }
}

for (const mode of modes) {
  for (const backend of backends) foo(backend, mode);
  for (const backend of controls) native(backend, mode);
}

function paired(mode) {
  for (const name of expected) {
    const participants = measured.get(name).filter(item => item.mode === mode);
    const rounds = name === "startup" ? repetitions : iterations;
    const prelude = name === "startup" ? priming : warmup;
    const samples = new Map(participants.map(item => [item, []]));
    const allocations = new Map(participants.map(item => [item, []]));
    const run = item => {
      const args = item.implementation === "foo" ? [] : [name, String(cpus().length)];
      const settings = item.implementation === "foo"
        ? { env: { ...process.env, FOO_BENCHMARK_METRICS: "1" } } : {};
      const started = performance.now();
      const observation = execute(item.binary.artifact, args, settings);
      return { ms: performance.now() - started,
        allocation: metrics(observation.stderr + observation.stdout) };
    };
    for (let index = 0; index < prelude; index++)
      for (const item of participants) run(item);
    for (let index = 0; index < rounds; index++) {
      const offset = index % participants.length;
      const order = [...participants.slice(offset), ...participants.slice(0, offset)];
      if (index % 2) order.reverse();
      for (const item of order) {
        const observed = run(item);
        samples.get(item).push(observed.ms);
        allocations.get(item).push(observed.allocation);
      }
    }
    for (const item of participants) {
      Object.assign(item, summary(samples.get(item)));
      item.allocationSamples = allocations.get(item);
      item.allocation = item.allocationSamples.at(-1);
      item.pairedResampled = true;
      item.pairedRounds = rounds;
      item.baselineResampled = name === "startup";
      budget(name, `${item.implementation}/${item.backend}/${mode}`, item.allocationSamples);
      console.log(`${name.padEnd(12)} ${item.implementation}/${item.backend} ${mode} paired median ${item.medianMs.toFixed(2)} ms`);
    }
    checkpoint();
  }
}
for (const mode of modes) paired(mode);

if (controls.includes("c") && controls.includes("cpp")) {
  for (const [name, results] of measured) for (const mode of modes) {
    const c = results.find(item => item.implementation === "native" && item.backend === "c" && item.mode === mode);
    const cpp = results.find(item => item.implementation === "native" && item.backend === "cpp" && item.mode === mode);
    if (JSON.stringify(c?.allocation) !== JSON.stringify(cpp?.allocation))
      throw Error(`${name}/${mode}: shared C/C++ control metrics differ`);
  }
}

for (const mode of modes) for (const backend of new Set([...backends, ...controls])) {
  for (const implementation of ["foo", "native"]) {
    const baseline = measured.get("startup")?.find(item => item.mode === mode && item.backend === backend && item.implementation === implementation);
    const runtime = measured.get("runtime")?.find(item => item.mode === mode && item.backend === backend && item.implementation === implementation);
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
    result.comparisons = Object.fromEntries(controls.map(backend => {
      const native = results.find(item => item.implementation === "native" &&
        item.backend === backend && item.mode === result.mode);
      if (!native) throw Error(`Missing ${backend}/${result.mode} control`);
      const differences = result.samplesMs.map((value, index) =>
        value - native.samplesMs[index]);
      return [backend, { medianMs: native.medianMs,
        speedup: native.medianMs / result.medianMs,
        slower: result.medianMs > native.medianMs,
        pairedWins: differences.filter(value => value < 0).length,
        pairedRounds: differences.length,
        pairedMedianDeltaMs: summary(differences).medianMs }];
    }));
    if (result.comparisons.rust) {
      result.rustMedianMs = result.comparisons.rust.medianMs;
      result.speedupAgainstRust = result.comparisons.rust.speedup;
      result.fasterThanRust = result.medianMs < result.comparisons.rust.medianMs;
    }
  }
}

const processors = cpus();
const report = {
  schema: "foo.benchmark/v4", measuredAt: new Date().toISOString(),
  ...(workload ? { selection: workload } : {}),
  compiler: manifest.version, warmup, iterations, referenceControls: controls,
  ...(compilerPath ? { selectedCompiler: compilerPath,
    selectedCompilerSha256: createHash("sha256").update(read(compilerPath)).digest("hex") } : {}),
  controlSources: { c: "benchmark/controls/c/native.c", cpp: "benchmark/controls/c/native.cpp (shared C/C++ fixture)",
    rust: "benchmark/controls/rust/native.rs", zig: "benchmark/controls/zig/native.zig" },
  baselineWarmup: priming, baselineIterations: repetitions,
  measurementOrder: "Rotating FOO and native controls within each workload after compilation",
  caution: "Startup-adjusted values and speed ratios are estimates. Compare raw samples and allocation/optimization evidence before attributing a difference to FOO. A workload result is not a language-wide speed claim.",
  machine: {
    platform: `${platform()} ${release()}`, architecture: arch(),
    processor: processors[0]?.model ?? "unknown", logicalCores: processors.length,
    memoryGiB: Number((totalmem() / 1024 ** 3).toFixed(1)),
  },
  workloads: expected.map(name => ({
    name, file: `benchmark/workloads/${name}.iv`, purpose: catalog[name].purpose,
    work: catalog[name].work, metricBudget: catalog[name].metricBudget,
    results: measured.get(name),
  })),
};
const output = resolve(option("--output") || resolve(benchmarkRun, "report.json"));
mkdir(dirname(output), { recursive: true });
write(output, `${JSON.stringify(report, null, 2)}\n`);
console.log(`Wrote ${output}`);
