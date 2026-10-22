import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.platform !== 'win32' || process.arch !== 'x64')
  throw Error('The vendored TinyCC Windows build requires a Windows x64 host');

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const source = join(root, 'vendor/tcc');
const output = join(root, '.artifacts/toolchain/tcc/vendor-build/source');
const allowed = join(root, '.artifacts/toolchain/tcc/vendor-build');
const within = relative(allowed, output);
if (!within || within === '..' || within.startsWith('..' + sep))
  throw Error(`Unsafe TinyCC build directory: ${output}`);
if (!existsSync(join(source, 'COPYING')) || !existsSync(join(source, 'tcc_vectorcall_abi.h')))
  throw Error('Vendored TinyCC source is incomplete');

mkdirSync(allowed, { recursive: true });
rmSync(output, { recursive: true, force: true });
cpSync(source, output, { recursive: true });
const compiler = process.env.FOO_TCC_BOOTSTRAP_CC ||
  join(root, 'vendor/tcc/bootstrap/windows-x64/tcc.exe');
if (!existsSync(compiler)) throw Error(`TinyCC bootstrap compiler missing: ${compiler}`);
const build = spawnSync('cmd.exe', ['/d', '/s', '/c', 'build-tcc.bat', '-c', compiler,
  '-t', 'x86_64'], { cwd: join(output, 'win32'), stdio: 'inherit', windowsHide: true });
if (build.error) throw build.error;
if (build.status !== 0) process.exit(build.status || 1);
const tcc = join(output, 'win32/tcc.exe');
const probe = spawnSync(tcc, ['-v'], { encoding: 'utf8', windowsHide: true });
if (probe.error || probe.status !== 0)
  throw Error(`Built TinyCC failed its version probe: ${probe.error?.message || probe.stderr}`);
console.log(`Built vendored TinyCC: ${tcc}`);
