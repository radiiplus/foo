import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { cpus } from 'node:os';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

function option(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1]) throw Error(`${name} requires a value`);
  return process.argv[index + 1];
}

const candidate = resolve(option('--candidate'));
const rust = resolve(option('--rust'));
const output = resolve(option('--output'));
const pairs = Number(option('--pairs'));
const warmups = Number(option('--warmups'));
const feature = process.argv.includes('--feature') ? option('--feature') : 'text';
if (!['text', 'decimal', 'record', 'json', 'table'].includes(feature))
  throw Error(`Unknown feature: ${feature}`);
if (!Number.isInteger(pairs) || pairs < 1 ||
    !Number.isInteger(warmups) || warmups < 1)
  throw Error('Positive integer --pairs and --warmups are required');

const sha256 = path => createHash('sha256').update(readFileSync(path)).digest('hex');
function run(path, control) {
  const start = process.hrtime.bigint();
  const child = spawnSync(path, [], {
    env: control ? { ...process.env, FOO_FEATURE_CASE: feature } : process.env,
    encoding: 'utf8', timeout: 180_000,
  });
  if (child.error || child.status !== 0)
    throw Error(`${path} failed: ${child.error?.message || child.stderr || child.stdout}`);
  return { ms: Number(process.hrtime.bigint() - start) / 1e6,
    stdout: child.stdout || '', stderr: child.stderr || '' };
}
function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] :
    (sorted[middle - 1] + sorted[middle]) / 2;
}

const result = {
  format: 'foo.qbe.experimental-runtime-compiler.v1',
  qualification: 'none', target: 'linux-x64', feature,
  compilerFlags: option('--compiler-flags'),
  hardware: cpus()[0]?.model || '', pairs, warmups,
  candidate: { path: candidate, sha256: sha256(candidate) },
  rust: { path: rust, sha256: sha256(rust) },
  warmupSamples: [], samples: [], complete: false,
};
const save = () => writeFileSync(output, JSON.stringify(result, null, 2) + '\n');
save();
for (let index = 0; index < warmups; ++index)
  result.warmupSamples.push({ candidate: run(candidate, false),
    rust: run(rust, true) });
for (let index = 0; index < pairs; ++index) {
  result.samples.push(index % 2 === 0
    ? { order: 'candidate-rust', candidate: run(candidate, false),
        rust: run(rust, true) }
    : { order: 'rust-candidate', rust: run(rust, true),
        candidate: run(candidate, false) });
  save();
}
const savings = result.samples.map(sample => sample.rust.ms - sample.candidate.ms);
result.summary = {
  medianCandidateMs: median(result.samples.map(sample => sample.candidate.ms)),
  medianRustMs: median(result.samples.map(sample => sample.rust.ms)),
  medianPairedSavingMs: median(savings),
  wins: savings.filter(value => value > 0).length,
  minimumPairedSavingMs: Math.min(...savings),
  maximumPairedSavingMs: Math.max(...savings),
};
result.complete = true;
save();
console.log(`Experimental runtime: ${result.summary.wins}/${pairs} QBE wins`);
