import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { closeSync, createReadStream, createWriteStream, existsSync, mkdirSync, openSync, readdirSync, renameSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const cache = join(homedir(), '.foo', 'upgrades');
const endpoint = 'https://api.github.com/repos/radiiplus/foo/releases/latest';

export function compare(left, right) {
  const parse = value => {
    if (!/^\d+\.\d+\.\d+$/.test(value)) throw Error(`Unsupported FOO version: ${value}`);
    return value.split('.').map(Number);
  };
  const a = parse(left), b = parse(right);
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return Math.sign(a[i] - b[i]);
  return 0;
}

export function installer(platform = process.platform, architecture = process.arch) {
  if (platform === 'win32' && architecture === 'x64') return 'foo-windows-x64.exe';
  if (platform === 'linux' && architecture === 'x64') return 'foo-amd64.deb';
  if (platform === 'linux' && architecture === 'arm64') return 'foo-arm64.deb';
  throw Error(`No FOO installer for ${platform}-${architecture}.`);
}

export function select(release, current, platform = process.platform, architecture = process.arch) {
  const latest = release.tag_name?.match(/^foo-v(\d+\.\d+\.\d+)$/)?.[1];
  if (!latest) throw Error('Latest FOO release has an unrecognized version tag.');
  if (compare(latest, current) <= 0) return { latest, current: true };
  const name = installer(platform, architecture);
  const asset = release.assets?.find(item => item.name === name);
  const sha256 = asset?.digest?.match(/^sha256:([0-9a-f]{64})$/)?.[1];
  const url = asset?.browser_download_url;
  if (!sha256 || !url || !url.startsWith(`https://github.com/radiiplus/foo/releases/download/${release.tag_name}/`))
    throw Error(`FOO ${latest} does not publish a verified ${name} package.`);
  return { latest, current: false, name, sha256, url };
}

function installation() {
  if (process.platform === 'linux' && root === '/opt/foo') return 'deb';
  if (process.platform === 'win32' && existsSync(root) &&
      readdirSync(root).some(name => /^unins\d+\.exe$/i.test(name))) return 'inno';
  throw Error('This FOO installation is not managed by the Windows or Debian installer. Upgrade it with the package manager used to install it.');
}

async function checksum(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

async function download(asset) {
  const directory = join(cache, asset.latest);
  const destination = join(directory, asset.name);
  mkdirSync(directory, { recursive: true });
  if (existsSync(destination) && await checksum(destination) === asset.sha256) return destination;
  const response = await fetch(asset.url, { headers: { 'User-Agent': 'foo-upgrade' } });
  if (!response.ok || !response.body) throw Error(`FOO upgrade download failed: HTTP ${response.status}`);
  const partial = destination + '.partial';
  try {
    await pipeline(Readable.fromWeb(response.body), createWriteStream(partial));
    if (await checksum(partial) !== asset.sha256) throw Error('FOO upgrade package checksum mismatch.');
    renameSync(partial, destination);
  } finally { rmSync(partial, { force: true }); }
  return destination;
}

async function handoff(file, expected, parent) {
  if (!resolve(file).startsWith(resolve(cache) + '\\') ||
      !/^[0-9a-f]{64}$/.test(expected) || await checksum(file) !== expected)
    throw Error('FOO upgrade installer is outside the verified cache or its checksum changed.');
  for (let attempt = 0; attempt < 600; attempt++) {
    try { process.kill(parent, 0); } catch { break; }
    await new Promise(done => setTimeout(done, 100));
  }
  try { process.kill(parent, 0); throw Error('FOO did not exit before installer handoff.'); } catch (error) {
    if (error.message === 'FOO did not exit before installer handoff.') throw error;
  }
  const log = openSync(join(dirname(file), 'upgrade.log'), 'a');
  try {
    const child = spawn(file, ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
      `/LOG=${join(dirname(file), 'install.log')}`], {
      detached: true, stdio: ['ignore', log, log], windowsHide: true,
    });
    await new Promise((done, fail) => { child.once('spawn', done); child.once('error', fail); });
    child.unref();
  } finally { closeSync(log); }
}

export async function upgrade(current, { check = false, parent = process.ppid } = {}) {
  const response = await fetch(endpoint, { headers: { 'Accept': 'application/vnd.github+json', 'User-Agent': 'foo-upgrade' } });
  if (!response.ok) throw Error(`Cannot check FOO releases: HTTP ${response.status}`);
  const asset = select(await response.json(), current);
  if (asset.current) return `FOO ${current} is up to date.`;
  if (check) return `FOO ${current} -> ${asset.latest} (${asset.name})`;
  const kind = installation();
  const file = await download(asset);
  if (kind === 'deb') {
    const command = process.getuid?.() === 0 ? 'dpkg' : 'sudo';
    const args = command === 'dpkg' ? ['-i', file] : ['dpkg', '-i', file];
    const result = spawnSync(command, args, { stdio: 'inherit' });
    if (result.error || result.status !== 0) throw Error(`FOO upgrade failed: ${result.error?.message ?? result.status}`);
    return `FOO upgraded to ${asset.latest}.`;
  }
  const log = openSync(join(dirname(file), 'upgrade.log'), 'a');
  try {
    const helper = spawn(process.execPath, [fileURLToPath(import.meta.url), '--apply-windows', file, asset.sha256, String(parent)], {
      detached: true, stdio: ['ignore', log, log], windowsHide: true,
    });
    await new Promise((done, fail) => { helper.once('spawn', done); helper.once('error', fail); });
    helper.unref();
  } finally { closeSync(log); }
  return `Verified FOO ${asset.latest}; installer will start after this command exits. Log: ${join(dirname(file), 'install.log')}`;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv[2] === '--apply-windows') await handoff(process.argv[3], process.argv[4], Number(process.argv[5]));
    else {
      const version = process.argv[2];
      const position = process.argv.indexOf('--parent');
      const parent = position >= 0 ? Number(process.argv[position + 1]) : process.ppid;
      const options = process.argv.slice(3).filter((_, index) =>
        position < 0 || index + 3 < position || index + 3 > position + 1);
      if (!version || !Number.isSafeInteger(parent) || parent <= 0 || options.some(arg => arg !== '--check'))
        throw Error('Usage: foo upgrade [--check]');
      console.log(await upgrade(version, { check: options.includes('--check'), parent }));
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
