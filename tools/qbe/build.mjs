import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const source = resolve(process.argv[2] || join(root, 'vendor/qbe'));
const tcc = resolve(process.argv[3] || join(root, '.artifacts/toolchain/tcc/vendor-build/source/win32/tcc.exe'));
const output = resolve(process.argv[4] || join(root, '.artifacts/toolchain/qbe/qbe-win.exe'));
const sources = [
  'main.c', 'util.c', 'parse.c', 'abi.c', 'cfg.c', 'mem.c', 'ssa.c', 'alias.c',
  'load.c', 'copy.c', 'fold.c', 'gvn.c', 'gcm.c', 'simpl.c', 'ifopt.c', 'live.c',
  'spill.c', 'rega.c', 'emit.c', 'amd64/targ.c', 'amd64/sysv.c', 'amd64/isel.c',
  'amd64/emit.c', 'amd64/winabi.c', 'arm64/targ.c', 'arm64/abi.c',
  'arm64/isel.c', 'arm64/emit.c', 'rv64/targ.c', 'rv64/abi.c', 'rv64/isel.c',
  'rv64/emit.c',
];
for (const path of [...sources.map(path => join(source, path)), tcc])
  if (!existsSync(path)) throw Error(`QBE build input missing: ${path}`);
mkdirSync(dirname(output), { recursive: true });
const args = ['-std=c99', '-I' + join(root, 'tools/qbe'), ...sources,
  join(root, 'tools/qbe/getopt.c'), '-o', output];
const built = spawnSync(tcc, args, { cwd: source, stdio: 'inherit', windowsHide: true });
if (built.error) throw built.error;
if (built.status !== 0) process.exit(built.status || 1);
const probe = spawnSync(output, ['-t', '?'], { encoding: 'utf8', windowsHide: true });
if (probe.status !== 0 || !probe.stdout.includes('amd64_sysv'))
  throw Error(`Native QBE target probe failed: ${probe.stderr || probe.stdout}`);
console.log(`Built native QBE: ${output}`);
