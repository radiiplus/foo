import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { cpus, platform, release } from 'node:os';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

function option(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1]) throw Error(`${name} requires a value`);
  return process.argv[index + 1];
}
const gate = resolve(option('--qualification'));
const root = resolve(import.meta.dirname, '../../..');
const rust = resolve(option('--rust'));
const output = resolve(option('--output'));
const pairs = Number(option('--pairs'));
const warmups = Number(option('--warmups'));
if (!Number.isInteger(pairs) || pairs < 1 ||
    !Number.isInteger(warmups) || warmups < 1)
  throw Error('Positive integer --pairs and --warmups are required');
const accepted = JSON.parse(readFileSync(gate));
if (!accepted.passed || accepted.target !== 'windows-x64')
  throw Error('A passing Windows x64 QBE feature qualification is required');
const names = ['text', 'decimal', 'record', 'json', 'table'];
const sha256 = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const controls = Object.fromEntries(names.map(name => [name,
  resolve(option(`--baseline-${name}`))]));
for (const path of [rust, ...Object.values(controls)])
  if (!existsSync(path)) throw Error(`Control executable missing: ${path}`);
const result = {
  format: 'foo.qbe.hosted-release-benchmark.v1',
  target: accepted.target, pairs, warmups,
  hardware: cpus()[0]?.model || '', os: `${platform()} ${release()}`,
  qualification: gate, qualificationSha256: sha256(gate),
  rust: { path: rust, sha256: sha256(rust),
    manifest: 'benchmark/features/rust/Cargo.lock',
    manifestSha256: sha256(join(root, 'benchmark/features/rust/Cargo.lock')) },
  features: {}, complete: false,
};
function save() { writeFileSync(output, JSON.stringify(result, null, 2) + '\n'); }
function run(path, name, rustControl = false) {
  const env = rustControl ? { ...process.env, FOO_FEATURE_CASE: name } : process.env;
  const start = process.hrtime.bigint();
  const processResult = spawnSync(path, [], { env, encoding: 'utf8', timeout: 180_000 });
  const elapsedMs = Number(process.hrtime.bigint() - start) / 1e6;
  if (processResult.error || processResult.status !== 0)
    throw Error(`${path} failed: ${processResult.error?.message || processResult.stderr || processResult.stdout}`);
  return { ms: elapsedMs, stdout: processResult.stdout || '',
    stderr: processResult.stderr || '' };
}
function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] :
    (sorted[middle - 1] + sorted[middle]) / 2;
}
function summary(samples) {
  const differences = samples.map(pair => pair.control.ms - pair.qbe.ms);
  return { medianQbeMs: median(samples.map(pair => pair.qbe.ms)),
    medianControlMs: median(samples.map(pair => pair.control.ms)),
    medianPairedSavingMs: median(differences),
    wins: differences.filter(value => value > 0).length,
    minimumPairedSavingMs: Math.min(...differences),
    maximumPairedSavingMs: Math.max(...differences) };
}
save();
for (const name of names) {
  const row = accepted.cases.find(item => item.mode === 'release' && item.name === name);
  if (!row) throw Error(`Missing release feature: ${name}`);
  const qbe = join(dirname(gate), `release-${name}`, '.artifacts', 'build', 'app.exe');
  if (sha256(qbe) !== row.artifactSha256)
    throw Error(`QBE executable changed since qualification: ${name}`);
  const metadata = JSON.parse(readFileSync(`${qbe}.qbe.json`));
  const feature = result.features[name] = {
    qbe: { path: qbe, sha256: row.artifactSha256, metadata },
    baseline: { path: controls[name], sha256: sha256(controls[name]) },
    comparisons: {},
  };
  for (const [label, control, rustControl] of [
    ['baseline', controls[name], false], ['rust', rust, true]]) {
    const comparison = feature.comparisons[label] = { warmups: [], samples: [] };
    for (let index = 0; index < warmups; ++index) {
      comparison.warmups.push({ qbe: run(qbe, name),
        control: run(control, name, rustControl) });
    }
    for (let index = 0; index < pairs; ++index) {
      const sample = index % 2 === 0
        ? { order: 'qbe-control', qbe: run(qbe, name),
            control: run(control, name, rustControl) }
        : { order: 'control-qbe', control: run(control, name, rustControl),
            qbe: run(qbe, name) };
      comparison.samples.push(sample);
      save();
    }
    comparison.summary = summary(comparison.samples);
    save();
    console.log(`${name}/${label}: ${comparison.summary.wins}/${pairs} QBE wins`);
  }
}
result.complete = true;
save();
console.log(`QBE paired benchmark: complete (${output})`);
