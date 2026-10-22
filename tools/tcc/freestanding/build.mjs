import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync,
  mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const source = join(root, 'src/runtime/qbe.c');
const output = join(root, 'vendor/tcc/freestanding');
const provided = process.env.FOO_QBE_TCC_BUILD;
const temporary = provided ? '' : mkdtempSync(join(tmpdir(), 'qbe-integer-tcc-'));
const build = provided ? resolve(provided) : join(temporary, 'source');

function run(program, args, cwd = root) {
  const result = spawnSync(program, args, { cwd, encoding: 'utf8' });
  if (result.error || result.status !== 0)
    throw Error(`${program}: ${result.error?.message || result.stderr || result.stdout}`);
  return result.stdout;
}

function sha256(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}

if (process.platform !== 'linux' || process.arch !== 'x64')
  throw Error('Build the freestanding integer objects on Linux x64 or WSL');

try {
  if (!provided) {
    cpSync(join(root, 'vendor/tcc'), build, { recursive: true,
      filter: path => !path.split(/[\\/]/).includes('.git') });
    const configure = join(build, 'configure');
    writeFileSync(configure, readFileSync(configure, 'utf8').replaceAll('\r\n', '\n'));
    chmodSync(configure, 0o755);
    run('sh', ['configure', `--prefix=${join(temporary, 'install')}`], build);
    run('make', ['-j2', 'tcc', 'arm64-tcc', 'riscv64-tcc'], build);
  }
  mkdirSync(output, { recursive: true });
  const objects = {};
  for (const [target, compiler, name] of [
    ['x64-freestanding', 'tcc', 'qbe-integer-x64.elfobj'],
    ['arm64-freestanding', 'arm64-tcc', 'qbe-integer-arm64.elfobj'],
    ['riscv64-freestanding', 'riscv64-tcc', 'qbe-integer-rv64.elfobj'],
  ]) {
    const destination = join(output, name);
    run(join(build, compiler), [`-B${build}`, '-DFOO_QBE_INTEGER_ONLY',
      '-c', 'src/runtime/qbe.c', '-o', destination]);
    const symbols = run('readelf', ['-Ws', destination]);
    if (/\bGLOBAL\s+DEFAULT\s+UND\b/.test(symbols))
      throw Error(`${target} integer object has unresolved symbols`);
    objects[target] = sha256(destination);
  }
  writeFileSync(join(output, 'manifest.json'),
    JSON.stringify({ sourceSha256: sha256(source), objects }, null, 2) + '\n');
  console.log(`Built freestanding integer objects in ${output}`);
} finally {
  if (temporary && existsSync(temporary)) rmSync(temporary, { recursive: true });
}
