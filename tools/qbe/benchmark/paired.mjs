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
const candidate = resolve(option('--candidate'));
const baseline = process.argv.includes('--baseline') ? resolve(option('--baseline')) : '';
const rust = resolve(option('--rust'));
const output = resolve(option('--output'));
const pairs = Number(option('--pairs'));
const warmups = Number(option('--warmups'));
const featureOnly = process.argv.includes('--feature-only');
if (!Number.isInteger(pairs) || pairs < 1 ||
    !Number.isInteger(warmups) || warmups < 1)
  throw Error('Positive integer --pairs and --warmups are required');
const root = resolve(import.meta.dirname, '../../..');
const allNames = ['text', 'decimal', 'record', 'json', 'table'];
const selected = process.argv.includes('--feature') ? option('--feature') : '';
if (selected && !allNames.includes(selected))
  throw Error(`Unknown feature: ${selected}`);
const names = selected ? [selected] : allNames;
const sha256 = path => createHash('sha256').update(readFileSync(path)).digest('hex');
function qualification(path) {
  const report = JSON.parse(readFileSync(path));
  if (!['linux-x64', 'windows-x64'].includes(report.target) ||
      (!report.passed && !featureOnly))
    throw Error(`A passing hosted qualification is required: ${path}`);
  if (!report.passed && names.some(name =>
      !['dev', 'release'].every(mode => report.cases.some(item =>
        item.name === name && item.mode === mode && item.status === 'qualified'))))
    throw Error(`Feature-only qualification is incomplete: ${path}`);
  return report;
}
const candidateGate = qualification(candidate);
const baselineGate = baseline ? qualification(baseline) : null;
if (baselineGate && candidateGate.target !== baselineGate.target)
  throw Error('Candidate and baseline targets must match');
const artifactName = candidateGate.target === 'windows-x64' ? 'app.exe' : 'app';
function artifact(gate, report, name) {
  const row = report.cases.find(item => item.mode === 'release' && item.name === name);
  if (!row || row.runExit !== 0) throw Error(`Unqualified release case: ${name}`);
  const path = join(dirname(gate), `release-${name}`, '.artifacts', 'build', artifactName);
  if (!existsSync(path) || sha256(path) !== row.artifactSha256)
    throw Error(`Qualified executable changed: ${path}`);
  return { path, sha256: row.artifactSha256,
    metadata: JSON.parse(readFileSync(`${path}.qbe.json`)) };
}
if (!existsSync(rust)) throw Error(`Rust executable missing: ${rust}`);
const result = {
  format: baseline ? 'foo.qbe.paired.v1' : 'foo.qbe.rust-paired.v1',
  target: candidateGate.target,
  qualification: candidateGate.passed && (!baselineGate || baselineGate.passed) ?
    'hosted-release' : 'feature-only',
  pairs, warmups, hardware: cpus()[0]?.model || '',
  os: `${platform()} ${release()}`,
  candidate: { qualification: candidate, sha256: sha256(candidate) },
  ...(baseline ? { baseline: { qualification: baseline,
    sha256: sha256(baseline) } } : {}),
  rust: { path: rust, sha256: sha256(rust),
    lockSha256: sha256(join(root, 'benchmark/features/rust/Cargo.lock')) },
  features: {}, complete: false,
};
const save = () => writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
function run(path, name, rustControl = false) {
  const env = rustControl ? { ...process.env, FOO_FEATURE_CASE: name } : process.env;
  const start = process.hrtime.bigint();
  const child = spawnSync(path, [], { env, encoding: 'utf8', timeout: 180_000 });
  const ms = Number(process.hrtime.bigint() - start) / 1e6;
  if (child.error || child.status !== 0)
    throw Error(`${path} failed: ${child.error?.message || child.stderr || child.stdout}`);
  return { ms, stdout: child.stdout || '', stderr: child.stderr || '' };
}
function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}
save();
for (const name of names) {
  const candidateFile = artifact(candidate, candidateGate, name);
  const baselineFile = baselineGate ? artifact(baseline, baselineGate, name) : null;
  const feature = result.features[name] = {
    candidate: candidateFile,
    ...(baselineFile ? { baseline: baselineFile } : {}),
    comparisons: {},
  };
  const controls = baselineFile ? [['baseline', baselineFile.path, false],
    ['rust', rust, true]] : [['rust', rust, true]];
  for (const [label, control, isRust] of controls) {
    const comparison = feature.comparisons[label] = { warmups: [], samples: [] };
    for (let index = 0; index < warmups; ++index)
      comparison.warmups.push({ candidate: run(candidateFile.path, name),
        control: run(control, name, isRust) });
    for (let index = 0; index < pairs; ++index) {
      const sample = index % 2 === 0
        ? { order: 'candidate-control', candidate: run(candidateFile.path, name),
            control: run(control, name, isRust) }
        : { order: 'control-candidate', control: run(control, name, isRust),
            candidate: run(candidateFile.path, name) };
      comparison.samples.push(sample);
      save();
    }
    const savings = comparison.samples.map(sample =>
      sample.control.ms - sample.candidate.ms);
    comparison.summary = {
      medianCandidateMs: median(comparison.samples.map(sample => sample.candidate.ms)),
      medianControlMs: median(comparison.samples.map(sample => sample.control.ms)),
      medianPairedSavingMs: median(savings),
      wins: savings.filter(value => value > 0).length,
      minimumPairedSavingMs: Math.min(...savings),
      maximumPairedSavingMs: Math.max(...savings),
    };
    save();
    console.log(`${name}/${label}: ${comparison.summary.wins}/${pairs} candidate wins`);
  }
}
result.complete = true;
save();
