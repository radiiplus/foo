import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync,
  writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../../..');
function option(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1]) throw Error(`${name} requires a value`);
  return process.argv[index + 1];
}
const compiler = resolve(option('--compiler'));
const target = option('--target');
const runner = process.argv.includes('--runner') ? option('--runner') : '';
const compilerQualification = process.argv.includes('--compiler-qualification') ?
  resolve(option('--compiler-qualification')) : '';
const outputRoot = process.argv.includes('--output') ? resolve(option('--output')) :
  join(root, '.artifacts', 'qbe-hosted-release');
const probeAll = process.argv.includes('--probe-all');
const requireAll = process.argv.includes('--require-all');
if (!['windows-x64', 'linux-x64', 'linux-arm64'].includes(target))
  throw Error(`Unsupported hosted release target: ${target}`);
if (!existsSync(compiler)) throw Error(`Compiler missing: ${compiler}`);
if (target === 'linux-arm64' && !runner)
  throw Error('Linux ARM64 execution requires --runner');
mkdirSync(outputRoot, { recursive: true });
const directory = mkdtempSync(join(outputRoot, `${target}-`));
const sha256 = path => createHash('sha256').update(readFileSync(path)).digest('hex');
let sourceHashes;
if (compilerQualification) {
  sourceHashes = JSON.parse(readFileSync(compilerQualification)).sourceHashes;
} else {
  const runtimeHash = createHash('sha256');
  for (const source of [
    'qbe.c', 'provider/hosted.h', 'codec/json.h', 'codec/qbe.h',
    'memory/storage.h',
    'trace.c', 'atomic/rv64.s', 'atomic/x64.s', 'atomic/arm64.s',
    'volatile/x64.s', 'volatile/arm64.s', 'volatile/rv64.s',
  ]) runtimeHash.update(readFileSync(join(root, 'src/runtime', source)));
  sourceHashes = {
    emitterSha256: sha256(join(root, 'src/backend/qbe/emitter.nim')),
    layoutSha256: sha256(join(root, 'src/backend/qbe/layout.nim')),
    driverSha256: sha256(join(root, 'src/backend/qbe/driver.nim')),
    runtimeSha256: runtimeHash.digest('hex'),
  };
}
if (compilerQualification) {
  const previous = JSON.parse(readFileSync(compilerQualification));
  if (!previous.passed || previous.compilerSha256 !== sha256(compiler) ||
      !sourceHashes?.emitterSha256 || !sourceHashes?.driverSha256 ||
      !sourceHashes?.runtimeSha256)
    throw Error('Compiler qualification does not match this executable');
}
const report = {
  format: 'foo.qbe.hosted-release.v2', target, compiler, probeAll, requireAll,
  compilerSha256: sha256(compiler), sourceHashes, runner,
  compilerQualification,
  cases: [], passed: false,
};
const env = { ...process.env, FOO_LIB: join(root, 'lib'), FOO_OFFLINE: '1' };
const qualifiedCases = [
  ...['text', 'decimal', 'record', 'json', 'table'].map(name => ({
    name, group: 'features', source: join(root, 'benchmark/features', `${name}.iv`),
    copy: true,
  })),
  { name: 'json-semantics', group: 'codecs',
    source: join(root, 'test/backend/qbe/fixtures/json.iv'), copy: true },
  ...['cleanup', 'exits', 'arena', 'storage'].map(name => ({
    name, group: 'ownership',
    source: join(root, 'test/backend/qbe/fixtures', `${name}.iv`),
    copy: false,
  })),
  { name: 'bounds', group: 'ownership', expectedError: 'IndexOutOfBounds',
    source: join(root, 'test/backend/qbe/fixtures/bounds.iv'), copy: false },
  { name: 'file', group: 'services',
    source: join(root, 'test/backend/qbe/fixtures/file.iv'), copy: false },
  { name: 'file-errors', group: 'services',
    source: join(root, 'test/backend/qbe/fixtures/file/errors.iv'), copy: false },
  { name: 'memory-services', group: 'ownership',
    source: join(root, 'test/backend/qbe/fixtures/allocate.iv'), copy: false },
  ...[
    ['handling', 'ownership'], ['managed', 'ownership'],
    ['pointers', 'ownership'],
    ['sequences', 'ownership'], ['codecs', 'codecs'],
    ['malformed', 'codecs'],
    ['threads', 'threads'], ['atomic', 'threads'],
  ].map(([name, group]) => ({ name, group,
    source: join(root, 'test/backend/qbe/fixtures', `${name}.iv`),
    copy: false })),
  { name: 'codec-optionals', group: 'codecs',
    source: join(root, 'test/backend/qbe/fixtures/codec/optionals.iv'),
    copy: false },
  ...['wide', 'choice'].map(name => ({ name: `codec-${name}`,
    group: 'codecs',
    source: join(root, 'test/backend/qbe/fixtures/codec', `${name}.iv`),
    copy: false })),
  ...['serialization', 'packedjson', 'encoding', 'reference'].map(name => ({ name,
    group: 'codecs',
    source: join(root, 'test/backend/qbe/fixtures', `${name}.iv`),
    copy: false })),
  { name: 'checked-inline-overflow', group: 'optimization',
    expectedError: 'IntegerOverflow',
    source: join(root, 'test/backend/qbe/fixtures/checked/overflow.iv'),
    copy: false },
  { name: 'narrow-integers', group: 'optimization',
    source: join(root, 'test/backend/qbe/fixtures/checked/narrow.iv'),
    copy: false },
  ...[['narrow-overflow-u2', 'u2'], ['narrow-overflow-i4', 'i4'],
    ['narrow-overflow-u31-mul', 'u31'], ['narrow-overflow-i31-mul', 'i31'],
    ['narrow-overflow-u33-mul', 'u33'], ['narrow-overflow-i63-div', 'i63'],
    ['narrow-overflow-u63', 'u63']].map(([name, width]) => ({ name,
    group: 'optimization',
    expectedError: 'IntegerOverflow',
    source: join(root, 'test/backend/qbe/fixtures/checked/narrow/overflow',
      `${width}.iv`),
    copy: false })),
  { name: 'narrow-zero', group: 'optimization',
    expectedError: 'DivisionByZero',
    source: join(root, 'test/backend/qbe/fixtures/checked/narrow/zero.iv'),
    copy: false },
];
const openCases = [
  ...[
    ['net', 'services'], ['process', 'services'],
    ['host', 'services'], ['tasks', 'threads'],
    ['taskcancel', 'threads'], ['context', 'threads'],
  ].map(([name, group]) => ({ name, group,
    source: join(root, 'test/backend/qbe/fixtures', `${name}.iv`),
    copy: false })),
];
const cases = probeAll ? [...qualifiedCases, ...openCases] : qualifiedCases;
report.inventory = cases.map(({ name, group, source }) => ({
  name, group, sourceSha256: sha256(source) }));
function save() {
  writeFileSync(join(directory, 'report.json'), JSON.stringify(report, null, 2) + '\n');
}
save();
const failures = [];
for (const mode of ['dev', 'release']) {
  for (const { name, group, source, copy, expectedError } of cases) {
    const work = join(directory, `${mode}-${name}`);
    mkdirSync(work);
    copyFileSync(source, join(work, copy ? 'main.iv' : 'source.iv'));
    const built = spawnSync(compiler, ['build', copy ? 'main.iv' : source,
      '--backend', 'qbe',
      '--mode', mode, '--target', target, '--kind', 'exe', '--compact'], {
      cwd: work, env, encoding: 'utf8', timeout: 180_000,
    });
    const row = { mode, name, group, sourceSha256: sha256(source),
      qualification: openCases.some(item => item.name === name) ? 'probe' : 'required',
      buildExit: built.status,
      buildOutput: `${built.stdout || ''}${built.stderr || ''}`,
      buildError: built.error?.message || '' };
    report.cases.push(row);
    save();
    const artifact = join(work, '.artifacts', 'build',
      target === 'windows-x64' ? 'app.exe' : 'app');
    if (built.status !== 0 || built.error || !existsSync(artifact)) {
      row.status = row.qualification === 'probe' ? 'open' : 'failed';
      if (row.status === 'failed' || requireAll)
        failures.push(`${mode}/${name}: build`);
      console.error(`${target} ${mode}/${name}: build failed`);
      save();
      continue;
    }
    const metadata = JSON.parse(readFileSync(`${artifact}.qbe.json`));
    const inlinePolicy = mode === 'release' && target !== 'linux-arm64' ?
      'private-guarded-constructor-v1' : 'disabled';
    const narrowIntegerPolicy = mode === 'release' &&
      target === 'windows-x64' && env.FOO_QBE_NARROW_INLINE !== '0' ?
      'inline-checked-w1-63-v1' : 'generic-checked-w1-63-v1';
    if (metadata.target !== target || metadata.mode !== mode ||
        metadata.backend !== 'qbe' || metadata.runtimeOptimization !== 'O0' ||
        metadata.checkedInlinePolicy !== inlinePolicy ||
        metadata.narrowIntegerPolicy !== narrowIntegerPolicy) {
      failures.push(`${mode}/${name}: identity`);
      row.status = 'failed';
      console.error(`${target} ${mode}/${name}: identity mismatch`);
      save();
      continue;
    }
    for (const [key, expected] of Object.entries(sourceHashes))
      if (metadata[key] !== expected)
        throw Error(`${mode}/${name} ${key} differs from current source`);
    row.artifactSha256 = sha256(artifact);
    row.metadataSha256 = sha256(`${artifact}.qbe.json`);
    row.runtimeOptimization = metadata.runtimeOptimization;
    const executed = spawnSync(runner || artifact,
      runner ? [artifact] : [], {
        cwd: work, env, encoding: 'utf8', timeout: 180_000,
      });
    row.runExit = executed.status;
    row.stdout = executed.stdout || '';
    row.stderr = executed.stderr || '';
    row.runError = executed.error?.message || '';
    save();
    const matchesExpectedError = expectedError && executed.status === 1 &&
      !executed.error && executed.stderr.trim() === expectedError;
    const succeeded = expectedError ? matchesExpectedError :
      executed.status === 0 && !executed.error;
    row.status = succeeded ? 'qualified' :
      row.qualification === 'probe' ? 'open' : 'failed';
    if (!succeeded) {
      if (row.status === 'failed' || requireAll)
        failures.push(`${mode}/${name}: execution`);
      console.error(`${target} ${mode}/${name}: execution failed`);
    } else console.log(`${target} ${mode}/${name}: ok ${row.artifactSha256}`);
    save();
  }
}
report.passed = failures.length === 0;
report.failures = failures;
report.openCases = report.cases.filter(row => row.status === 'open')
  .map(({ mode, name }) => `${mode}/${name}`);
report.fullyQualified = probeAll && report.passed && report.openCases.length === 0;
save();
if (failures.length)
  throw Error(`${failures.length} hosted QBE cases failed; see ${join(directory, 'report.json')}`);
console.log(`QBE hosted required cases: ok; ${report.openCases.length} open probes (${directory})`);
