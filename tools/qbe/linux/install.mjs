import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chmodSync, copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const source = resolve(join(root, 'vendor/tcc'));
const output = resolve(option('--output-root') || join(root, '.artifacts/toolchain'));
const tccOutput = join(output, 'tcc/linux-x64');
const muslOutput = join(output, 'musl');
const muslVersion = '1.2.5-r12';
const packages = [
  ['x64', 'x86_64', '1c2068d910cfdbbcb4eb107a5a478f8b48edf3a6311953c8fa5180c5190efab3'],
  ['arm64', 'aarch64', '576f4aabcfa01d10d6baa2d5d87de436b76e58ae76eedf9db7627051365e1fe3'],
];
const copyrightHash = 'f9bc4423732350eb0b3f7ed7e91d530298476f8fec0c6c427a1c04ade22655af';

function option(name) {
  const index = process.argv.indexOf(name);
  if (index >= 0 && !process.argv[index + 1]) throw Error(`${name} requires a path`);
  return index < 0 ? '' : process.argv[index + 1];
}
function run(binary, args, cwd = root) {
  const result = spawnSync(binary, args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  if (result.error || result.status !== 0)
    throw Error(`${binary} failed: ${result.error?.message || result.stderr || result.stdout}`);
  return result.stdout.trim();
}
function checksum(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex');
}
function acquire(urls, path, expected, cached = '') {
  if (cached) {
    if (!existsSync(cached)) throw Error(`Cached asset does not exist: ${cached}`);
    copyFileSync(cached, path);
    if (checksum(path) !== expected) throw Error(`Cached asset checksum mismatch: ${cached}`);
    return;
  }
  let failure;
  for (const url of urls) {
    try {
      run('curl', ['--fail', '--location', '--silent', '--show-error',
        '--retry', '4', '--retry-all-errors', '--retry-delay', '2',
        '--connect-timeout', '20', url, '--output', path]);
      if (checksum(path) !== expected) throw Error(`Asset checksum mismatch: ${url}`);
      return;
    } catch (error) { failure = error; }
  }
  throw failure;
}

if (process.platform !== 'linux' || process.arch !== 'x64')
  throw Error('Build Linux TinyCC assets on Linux x64 (WSL is supported)');
if (process.argv.includes('--source'))
  throw Error('Linux TinyCC assets must be built from vendor/tcc');
run(process.execPath, ['tools/vendor/audit.mjs']);
if (existsSync(tccOutput) || packages.some(([name]) => existsSync(join(muslOutput, name))))
  throw Error(`Linux toolchain destination already exists under ${output}`);

const temporary = mkdtempSync(join(tmpdir(), 'foo-linux-assets-'));
const created = [];
try {
  const license = join(temporary, 'musl-COPYRIGHT');
  acquire(['https://git.musl-libc.org/cgit/musl/plain/COPYRIGHT?h=v1.2.5'],
    license, copyrightHash, option('--copyright'));
  const archives = new Map();
  for (const [name, architecture, expected] of packages) {
    const archive = join(temporary, `musl-dev-${name}.apk`);
    const path = `/alpine/v3.22/main/${architecture}/musl-dev-${muslVersion}.apk`;
    acquire(['https://dl-cdn.alpinelinux.org',
      'https://dl-2.alpinelinux.org'].map(host => host + path),
      archive, expected, option(`--archive-${name}`));
    archives.set(name, archive);
  }
  for (const [name] of packages) {
    const archive = archives.get(name);
    const unpacked = join(temporary, `musl-${name}`);
    mkdirSync(unpacked);
    run('tar', ['--warning=no-unknown-keyword', '--ignore-zeros', '-xzf', archive, '-C', unpacked]);
    const destination = join(muslOutput, name);
    created.push(destination);
    mkdirSync(join(destination, 'usr/lib'), { recursive: true });
    cpSync(join(unpacked, 'usr/include'), join(destination, 'usr/include'), { recursive: true });
    for (const file of ['crt1.o', 'libc.a'])
      copyFileSync(join(unpacked, 'usr/lib', file), join(destination, 'usr/lib', file));
    copyFileSync(license, join(destination, 'COPYRIGHT'));
  }
  const build = join(temporary, 'tinycc');
  cpSync(source, build, { recursive: true, filter: path => !path.split(/[\\/]/).includes('.git') });
  const configure = join(build, 'configure');
  writeFileSync(configure, readFileSync(configure, 'utf8').replaceAll('\r\n', '\n'));
  chmodSync(configure, 0o755);
  run('./configure', ['--config-musl', `--sysroot=${join(muslOutput, 'x64')}`,
    `--prefix=${join(temporary, 'install')}`], build);
  run('make', ['-j2', 'tcc', 'libtcc1.a', 'cross-arm64'], build);
  created.push(tccOutput);
  mkdirSync(tccOutput, { recursive: true });
  for (const file of ['tcc', 'libtcc1.a', 'arm64-tcc', 'arm64-libtcc1.a', 'COPYING'])
    copyFileSync(join(build, file), join(tccOutput, file));
  for (const file of ['tcc', 'arm64-tcc']) chmodSync(join(tccOutput, file), 0o755);
  const bytes = ['tcc', 'libtcc1.a', 'arm64-tcc', 'arm64-libtcc1.a']
    .reduce((sum, file) => sum + statSync(join(tccOutput, file)).size, 0);
  console.log(`Installed pinned Linux TinyCC and musl assets under ${output} (${bytes} TinyCC bytes)`);
} catch (error) {
  for (const path of created.reverse()) {
    if (path.startsWith(output + sep)) rmSync(path, { recursive: true, force: true });
  }
  throw error;
} finally {
  if (!temporary.startsWith(resolve(tmpdir()) + sep))
    throw Error(`Refusing to remove unexpected build directory: ${temporary}`);
  rmSync(temporary, { recursive: true, force: true });
}
