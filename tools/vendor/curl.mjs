import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { value as option } from '../arguments.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const target = option('--target');
const triple = target === 'linux-musl-x64' ? 'x86_64-linux-musl'
  : target === 'linux-musl-arm64' ? 'aarch64-linux-musl' : '';
if (process.platform !== 'linux' || !triple)
  throw Error('Curl provisioning requires Linux x64 and a musl x64/ARM64 target');
const archive = resolve(option('--archive') || '');
const imported = option('--built');
const sdk = option('--openssl-dev');
const binaries = option('--openssl-static');
if (Boolean(sdk) !== Boolean(binaries))
  throw Error('Pass both --openssl-dev and --openssl-static for HTTPS curl');
const tls = Boolean(sdk);
if (!existsSync(archive)) throw Error('Pass --archive with the pinned curl source archive');
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const manifest = readFileSync(join(root, 'vendor/manifest.json'));
const locked = JSON.parse(manifest.toString()).dependencies.find(item => item.name === 'curl');
const lock = readFileSync(join(root, 'vendor/openssl-musl.json'));
const openssl = JSON.parse(lock).targets[target];
if (hash(readFileSync(archive)) !== locked.archiveSha256)
  throw Error('Curl source archive does not match the vendor lock');
if (tls && (!existsSync(sdk) || !existsSync(binaries) ||
    hash(readFileSync(sdk)) !== openssl.devSha256 ||
    hash(readFileSync(binaries)) !== openssl.staticSha256))
  throw Error('OpenSSL musl packages do not match the target lock');
const output = join(root, '.artifacts/vendor', target);
const receipt = join(output, 'provenance.json');
if (!existsSync(receipt)) throw Error('Provision libsodium/zlib before curl for ' + target);
const record = JSON.parse(readFileSync(receipt));
if (record.target !== target || record.vendorIdentity !== hash(manifest) ||
    !record.compilerTarget.startsWith(triple.split('-')[0] + '-') ||
    !record.compilerTarget.endsWith('-linux-musl'))
  throw Error('Existing native provenance does not match the curl target/vendor lock');
function run(command, args, cwd, env = {}) {
  const result = spawnSync(command, args, {
    cwd, env: { ...process.env, LC_ALL: 'C', TZ: 'UTC', SOURCE_DATE_EPOCH: '0', ...env },
    encoding: 'utf8', windowsHide: true, maxBuffer: 16 * 1024 * 1024
  });
  if (result.status !== 0)
    throw Error(`${command} ${args.join(' ')} failed: ${result.error?.message || result.stderr || result.stdout}`);
  return result.stdout;
}
if (run('zig', ['version'], root).trim() !== '0.11.0')
  throw Error('Curl musl provisioning requires Zig 0.11.0');
const scratch = mkdtempSync(join(tmpdir(), 'foo-musl-curl-'));
try {
  const flags = ['--host=' + triple, '--disable-shared', '--enable-static',
    tls ? '--with-openssl' : '--without-ssl',
    '--without-zlib', '--without-brotli', '--without-zstd',
    '--without-libpsl', '--without-libidn2', '--disable-manual', '--disable-ldap',
    '--disable-ldaps', '--disable-rtsp', '--disable-tftp', '--disable-ftp',
    '--disable-smtp', '--disable-pop3', '--disable-imap', '--disable-gopher',
    '--disable-mqtt', '--disable-smb', '--disable-telnet', '--disable-dict',
    '--disable-file', '--disable-proxy'];
  const env = { CC: `zig cc -target ${triple}`, CFLAGS: '-O2 -fPIC' };
  let assets = '';
  if (tls) {
    const dev = join(scratch, 'openssl-dev');
    assets = join(scratch, 'openssl-static');
    mkdirSync(dev);
    mkdirSync(assets);
    run('tar', ['-xzf', resolve(sdk), '-C', dev], root);
    run('tar', ['-xzf', resolve(binaries), '-C', assets], root);
    for (const name of ['libssl.a', 'libcrypto.a']) {
      const path = join(assets, 'usr/lib', name);
      if (!existsSync(path)) throw Error('OpenSSL package lacks ' + name);
    }
    env.CPPFLAGS = '-I' + join(dev, 'usr/include');
    env.LDFLAGS = '-static -L' + join(assets, 'usr/lib');
    env.PKG_CONFIG_LIBDIR = join(dev, 'usr/lib/pkgconfig');
  }
  let built = imported ? resolve(imported) : '';
  if (imported && !existsSync(built)) throw Error('Imported curl archive not found');
  if (!imported) {
    run('tar', ['-xzf', archive, '-C', scratch], root);
    const source = join(scratch, `curl-${locked.version}`);
    const build = join(scratch, 'build');
    mkdirSync(build);
    run('sh', [join(source, 'configure'), ...flags], build, env);
    run('make', ['-j2', '-C', 'lib'], build, env);
    built = join(build, 'lib/.libs/libcurl.a');
  }
  if (!run('nm', ['--defined-only', built], root).includes('curl_easy_init'))
    throw Error('Curl archive lacks curl_easy_init');
  if (tls && !run('nm', ['--undefined-only', built], root).includes('SSL_connect'))
    throw Error('Curl archive lacks its OpenSSL backend');
  const machine = target.endsWith('x64') ? 'Advanced Micro Devices X86-64' : 'AArch64';
  const headers = run('readelf', ['-h', built], root);
  if (!headers.includes(machine) || headers.split('\n').filter(line =>
      line.includes('Machine:')).some(line => !line.includes(machine)))
    throw Error('Curl archive has the wrong target architecture');
  const destination = join(output, 'curl/lib/libcurl.a');
  mkdirSync(dirname(destination), { recursive: true });
  copyFileSync(built, destination);
  record.files['curl/lib/libcurl.a'] = hash(readFileSync(destination));
  for (const name of ['libssl.a', 'libcrypto.a']) {
    const relative = 'curl/lib/' + name;
    if (!tls) {
      delete record.files[relative];
      continue;
    }
    const source = join(assets, 'usr/lib', name);
    const members = run('ar', ['t', source], root).trim().split('\n');
    const member = members.find(value => value.endsWith('.o'));
    if (!member) throw Error('OpenSSL archive lacks object members: ' + name);
    const inspection = join(scratch, name);
    mkdirSync(inspection);
    run('ar', ['x', source, member], inspection);
    if (!run('readelf', ['-h', join(inspection, member)], root).includes(machine))
      throw Error('OpenSSL archive has the wrong target architecture: ' + name);
    const destination = join(output, relative);
    copyFileSync(source, destination);
    record.files[relative] = hash(readFileSync(destination));
  }
  record.recipes = record.recipes.filter(item => item.dependency !== 'curl');
  record.recipes.push({ dependency: 'curl', sourceSha256: locked.archiveSha256,
    configure: flags, cflags: env.CFLAGS, symbol: 'curl_easy_init',
    architecture: machine, imported: Boolean(imported),
    tlsBackend: tls ? 'openssl-static' : 'none',
    ...(tls ? { opensslLockIdentity: hash(lock),
      opensslDevSha256: openssl.devSha256,
      opensslStaticSha256: openssl.staticSha256 } : {}),
    archiveSha256: hash(readFileSync(destination)) });
  writeFileSync(receipt, JSON.stringify(record, null, 2) + '\n');
  console.log(`Built controlled musl curl archive: ${destination}`);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
