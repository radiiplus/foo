import { spawnSync } from "node:child_process";
import { performance } from "node:perf_hooks";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { arch, cpus, platform, release } from "node:os";

const [foo, control, mode, outputFile, controlKind, fooFile, controlFile, countText] = process.argv.slice(2);
const iterations = countText === undefined ? 9 : Number(countText);
if (!foo || !control || !["a", "b", "r", "s"].includes(mode)) {
  console.error("Usage: node benchmark/compare.mjs FOO_EXE CONTROL_EXE a|b|r|s [OUTPUT_JSON] [native|foo] [FOO_TIME] [CONTROL_TIME] [SAMPLES]");
  process.exit(2);
}
if (!Number.isSafeInteger(iterations) || iterations < 1 || iterations > 1000)
  throw Error("SAMPLES must be an integer from 1 to 1000");

const defaultPath = mode === "a" ? ".artifacts/algebra.bin"
    : mode === "b" ? ".artifacts/bitmap.bin" : ".artifacts/radix.bin";
function run(command, args, path) {
  const printed = args.length && (mode !== "a" || controlKind === "native");
  if (!printed) rmSync(path, { force: true });
  const start = performance.now();
  const result = spawnSync(command, args, { encoding: "utf8", windowsHide: true });
  const elapsed = performance.now() - start;
  if (result.error || result.status !== 0)
    throw Error(result.error?.message || result.stderr || `${command} exited ${result.status}`);
  const output = result.stdout.trim();
  const nanos = printed
    ? /^\d+ \d+$/.test(output) && Number(output.split(" ")[0])
    : Number(readFileSync(path).readBigUInt64BE());
  if (!Number.isFinite(nanos) || nanos <= 0)
    throw Error(`Unexpected timing output: ${result.stdout}`);
  return { wallMs: elapsed, operationMs: nanos / 1e6 };
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

const controlArgs = mode === "a" && controlKind !== "native" ? [] : [mode];
for (let i = 0; i < 2; ++i) {
  run(foo, [], fooFile || defaultPath);
  run(control, controlArgs, controlFile || defaultPath);
}
const samples = { foo: [], control: [] };
for (let i = 0; i < iterations; ++i) {
  const order = i % 2 ? ["control", "foo"] : ["foo", "control"];
  for (const name of order)
    samples[name].push(name === "foo" ? run(foo, [], fooFile || defaultPath)
      : run(control, controlArgs, controlFile || defaultPath));
}
const wins = samples.foo.filter((sample, index) =>
  sample.operationMs < samples.control[index].operationMs).length;
function signProbability(successes, trials) {
  const tail = Math.max(successes, trials - successes);
  let combination = 1;
  let upper = 0;
  for (let index = 0; index <= trials; ++index) {
    if (index >= tail) upper += combination;
    combination *= (trials - index) / (index + 1);
  }
  return Math.min(1, 2 * upper / 2 ** trials);
}
const result = { mode, controlKind: controlKind || "foo", environment: {
    platform: platform(), release: release(), arch: arch(),
    cpu: cpus()[0]?.model, node: process.version,
  },
  operationMedianMs: {
    foo: median(samples.foo.map(sample => sample.operationMs)),
    control: median(samples.control.map(sample => sample.operationMs)),
  },
  processMedianMs: {
    foo: median(samples.foo.map(sample => sample.wallMs)),
    control: median(samples.control.map(sample => sample.wallMs)),
  }, samples,
  paired: { wins, samples: iterations, twoSidedSignP: signProbability(wins, iterations) },
};
const encoded = JSON.stringify(result, null, 2);
if (outputFile) writeFileSync(outputFile, `${encoded}\n`);
console.log(encoded);
