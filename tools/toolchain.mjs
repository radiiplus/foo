import { existsSync as exists, readFileSync as read, writeFileSync as save, mkdirSync as mkdir, mkdtempSync as scratch, renameSync as rename, readdirSync, statSync as stat, openSync, closeSync, unlinkSync, createWriteStream as writer } from 'node:fs';
import { join, resolve, dirname, delimiter } from 'node:path';
import { fileURLToPath as filename } from 'node:url';
import { homedir } from 'node:os';
import { execFileSync as invoke } from 'node:child_process';
import { createHash as hasher } from 'node:crypto';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const root = resolve(dirname(filename(import.meta.url)), '..');
const config = JSON.parse(read(join(root, 'toolchain.json'), 'utf8'));
export const version = config.zig;
const executable = process.platform === 'win32' ? 'zig.exe' : 'zig';
export function directory() { return resolve(process.env.FOO_HOME || root, '.artifacts/toolchain'); }
export function pin(project = process.cwd()) {
  const current = join(project, 'foo.ivl');
  const selected = exists(current) ? JSON.parse(read(current, 'utf8')).zig || version : version;
  if (selected !== version) throw Error(`This FOO compiler requires Zig ${version}; project foo.ivl requests ${selected}. Install a compatible FOO release.`);
  return selected;
}
export function verify(path, expected = version) {
  try { return invoke(path, ['version'], { encoding: 'utf8', timeout: 10000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }).trim() === expected; }
  catch { return false; }
}
export function detect(expected = version) {
  if (expected !== version) return undefined;
  const candidates = [join(directory(), expected, executable)];
  // Reuse older managed installations only after verifying the executable version.
  // Explicit FOO_HOME isolates portable installations and installation tests.
  if (!process.env.FOO_HOME) candidates.push(join(homedir(), '.foo/toolchains', expected, executable), join(homedir(), '.tratio/toolchains', expected, executable));
  for (const path of candidates) if (exists(path) && verify(path, expected)) return { version: expected, path };
}
export function list() { return exists(directory()) ? readdirSync(directory()).filter(name => /^\d+\.\d+\.\d+$/.test(name) && verify(join(directory(), name, executable), name)) : []; }
export function size(value) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 ** 2) return `${(value / 1024).toFixed(1)} KiB`;
  if (value < 1024 ** 3) return `${(value / 1024 ** 2).toFixed(1)} MiB`;
  return `${(value / 1024 ** 3).toFixed(1)} GiB`;
}
export function progress(downloaded, total, speed) {
  const percent = total > 0 ? Math.min(100, Math.floor(downloaded * 100 / total)) : 0;
  return `Downloaded ${size(downloaded)} / ${size(total)} (${percent}%) at ${size(speed)}/s`;
}
function report(message) { process.stderr.write(`  ${message}\n`); }
export function configure() {
  if (process.env.npm_config_global !== 'true' || process.env.FOO_PATH === 'skip') return;
  const prefix = process.env.npm_config_prefix;
  if (!prefix) return;
  const binary = process.platform === 'win32' ? resolve(prefix) : resolve(prefix, 'bin');
  if ((process.env.PATH || '').split(delimiter).some(path => resolve(path).toLowerCase() === binary.toLowerCase())) return;
  if (process.platform === 'win32') {
    const script = `$existing = [string][Environment]::GetEnvironmentVariable('Path', 'User'); $binary = $env:FOO_BIN; if (!(($existing -split ';') -contains $binary)) { [Environment]::SetEnvironmentVariable('Path', (($existing.TrimEnd(';') + ';' + $binary).TrimStart(';')), 'User') }`;
    invoke('powershell.exe', ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(script, 'utf16le').toString('base64')], { env: { ...process.env, FOO_BIN: binary }, windowsHide: true });
  } else {
    const profile = join(homedir(), process.env.SHELL?.endsWith('zsh') ? '.zprofile' : '.profile');
    const old = exists(profile) ? read(profile, 'utf8') : '';
    const quoted = "'" + binary.replaceAll("'", "'\\''") + "'";
    const line = `export PATH=${quoted}:"$PATH"`;
    if (!old.split('\n').includes(line)) save(profile, old + '\n' + line + '\n');
  }
  process.stderr.write('FOO was added to your user PATH. Open a new terminal to use foo.\n');
}
export async function install(expected = version) {
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (major < 22 || (major === 22 && minor < 13)) throw Error('FOO needs Node 22.13 or newer.');
  if (expected !== version) throw Error(`Unsupported backend version '${expected}'; this FOO release requires ${version}.`);
  const existing = detect(expected); if (existing) return existing;
  if (process.env.FOO_OFFLINE === "1") throw Error("Offline mode forbids toolchain downloads; bootstrap explicitly first.");
  const cache = directory(); mkdir(cache, { recursive: true });
  const lock = join(cache, `${expected}.lock`), deadline = Date.now() + 180000;
  let handle;
  while (handle === undefined) {
    try { handle = openSync(lock, 'wx'); }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      const ready = detect(expected); if (ready) return ready;
      if (Date.now() >= deadline) throw Error(`Toolchain installation is locked: ${lock}. Check for another installer before removing a stale lock.`);
      await new Promise(resolve => setTimeout(resolve, 200));
    }
  }
  try {
    const ready = detect(expected); if (ready) return ready;
    const platform = { win32: 'windows', darwin: 'macos', linux: 'linux' }[process.platform];
    const arch = { x64: 'x86_64', arm64: 'aarch64' }[process.arch];
    if (!platform || !arch) throw Error(`No managed toolchain for ${process.platform}/${process.arch}.`);
    process.stderr.write('FOO toolchain\n');
    report(`Resolving Zig ${expected} for ${arch}-${platform}`);
    const response = await fetch(config.index, { signal: AbortSignal.timeout(60000), redirect: 'error' });
    if (!response.ok) throw Error(`Toolchain index returned HTTP ${response.status}.`);
    const index = await response.json(), release = index[expected]?.[`${arch}-${platform}`];
    if (!release || !/^[a-f0-9]{64}$/.test(release.shasum) || !(Number(release.size) > 0 && Number(release.size) < 512 * 1024 * 1024)) throw Error('Invalid toolchain release metadata.');
    const url = new URL(release.tarball);
    if (url.protocol !== 'https:' || url.hostname !== 'ziglang.org') throw Error('Toolchain archive must come from ziglang.org over HTTPS.');
    const temporary = scratch(join(cache, 'download-')), archive = join(temporary, platform === 'windows' ? 'archive.zip' : 'archive.tar.xz');
    const expected = Number(release.size), started = Date.now(); let reported = 0;
    report(`Destination ${join(cache, expected)}`);
    report(`Downloading ${size(expected)} from ziglang.org`);
    const download = await fetch(url, { signal: AbortSignal.timeout(300000), redirect: 'error' });
    if (!download.ok || !download.body) throw Error(`Toolchain download returned HTTP ${download.status}.`);
    const hash = hasher('sha256'); let bytes = 0;
    const notify = (force = false) => {
      const now = Date.now();
      if (!force && now - reported < 1000) return;
      reported = now;
      const speed = Math.floor(bytes * 1000 / Math.max(1, now - started));
      report(progress(bytes, expected, speed));
    };
    await pipeline(Readable.fromWeb(download.body), new Transform({ transform(chunk, encoding, done) { bytes += chunk.length; if (bytes > expected) return done(Error('Toolchain archive exceeds its declared size.')); hash.update(chunk); notify(); done(null, chunk); } }), writer(archive, { flags: 'wx' }));
    notify(true);
    report('Verifying SHA-256 checksum');
    if (bytes !== expected || hash.digest('hex') !== release.shasum) throw Error(`Toolchain checksum failed. Download retained at ${archive}.`);
    report('Inspecting archive paths');
    const entries = invoke('tar', ['-tf', archive], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, windowsHide: true }).trim().split(/\r?\n/);
    if (entries.some(name => /^[\\/]|^[A-Za-z]:/.test(name) || name.split(/[\\/]/).includes('..'))) throw Error('Unsafe toolchain archive path.');
    const unpacked = join(temporary, 'unpacked'); mkdir(unpacked);
    report(`Extracting Zig ${expected}`);
    invoke('tar', ['-xf', archive, '-C', unpacked], { timeout: 300000, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    const directories = readdirSync(unpacked).filter(name => stat(join(unpacked, name)).isDirectory());
    if (directories.length !== 1) throw Error('Unexpected toolchain archive layout.');
    const installed = join(unpacked, directories[0]);
    report('Verifying downloaded executable');
    if (!verify(join(installed, executable), expected)) throw Error('Downloaded toolchain reports an incompatible version.');
    const target = join(cache, expected);
    report(`Installing Zig ${expected}`);
    if (exists(target)) rename(target, join(temporary, 'previous'));
    rename(installed, target);
    unlinkSync(archive);
    report(`Ready Zig ${expected} at ${join(target, executable)}`);
    return { version: expected, path: join(target, executable) };
  } finally { closeSync(handle); unlinkSync(lock); }
}

if (process.argv[1] && resolve(process.argv[1]) === filename(import.meta.url)) {
  install().then(configure).catch(error => { console.error(`FOO installation: ${error.message}\nRun foo doctor to inspect the toolchain, then foo install to retry.`); process.exitCode = 1; });
}
