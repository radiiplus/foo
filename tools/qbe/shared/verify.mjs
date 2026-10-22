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
const tcc = resolve(option('--tcc'));
const output = process.argv.includes('--output') ? resolve(option('--output')) :
  join(root, '.artifacts', 'qbe-shared');
if (!existsSync(compiler) || !existsSync(tcc))
  throw Error('QBE compiler and vendored TinyCC must exist');
mkdirSync(output, { recursive: true });
const directory = mkdtempSync(join(output, 'windows-x64-'));
const sha256 = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const fixture = join(root, 'test/backend/qbe/fixtures/project/shared');
const probe = join(directory, 'probe.exe');
const env = { ...process.env, FOO_QBE_TCC: tcc, FOO_OFFLINE: '1',
  FOO_LIB: join(root, 'lib') };
const compile = spawnSync(tcc, [join(root, 'test/backend/qbe/shared/probe.c'),
  '-o', probe], { cwd: directory, env, encoding: 'utf8' });
if (compile.status !== 0 || compile.error)
  throw Error(`Shared consumer compilation failed: ${compile.stderr || compile.error}`);
const report = { format: 'foo.qbe.shared-release.v1', target: 'windows-x64',
  compilerSha256: sha256(compiler), tccSha256: sha256(tcc), cases: [], passed: false };
function save() {
  writeFileSync(join(directory, 'report.json'), JSON.stringify(report, null, 2) + '\n');
}
save();
for (const mode of ['dev', 'release']) {
  const work = join(directory, mode);
  mkdirSync(join(work, 'src'), { recursive: true });
  copyFileSync(join(fixture, 'project.ivc'), join(work, 'project.ivc'));
  copyFileSync(join(fixture, 'src/library.iv'), join(work, 'src/library.iv'));
  const built = spawnSync(compiler, ['build', '--target', 'windows-x64',
    '--mode', mode, '--compact'], { cwd: work, env, encoding: 'utf8', timeout: 180_000 });
  const library = join(work, 'output', 'library.dll');
  const row = { mode, buildExit: built.status,
    buildOutput: `${built.stdout || ''}${built.stderr || ''}` };
  report.cases.push(row);
  save();
  if (built.status !== 0 || built.error || !existsSync(library))
    throw Error(`${mode} shared build failed: ${row.buildOutput || built.error}`);
  const metadata = JSON.parse(readFileSync(`${library}.qbe.json`));
  if (metadata.backend !== 'qbe' || metadata.target !== 'windows-x64' ||
      metadata.mode !== mode || metadata.cc.sha256 !== report.tccSha256)
    throw Error(`${mode} shared build metadata mismatch`);
  const run = spawnSync(probe, [library], {
    cwd: work, env, encoding: 'utf8', timeout: 30_000 });
  row.runExit = run.status;
  row.stdout = run.stdout || '';
  row.stderr = run.stderr || '';
  row.artifactSha256 = sha256(library);
  row.metadataSha256 = sha256(`${library}.qbe.json`);
  save();
  if (run.status !== 0 || run.error || !row.stdout.includes('QBE shared library: ok'))
    throw Error(`${mode} shared consumer failed: ${row.stderr || run.error || run.status}`);
  console.log(`windows-x64 ${mode}/shared: ok ${row.artifactSha256}`);
}
report.passed = true;
save();
console.log(`QBE Windows shared library: ok (${directory})`);
