// Offline license/content audit. Updates to the lock require explicit review.
import { readFileSync as read, readdirSync as entries, existsSync as exists } from 'node:fs';
import { createHash as hasher } from 'node:crypto';
import { resolve, join, relative, dirname } from 'node:path';
import { fileURLToPath as filename } from 'node:url';
import { spawnSync as invoke } from 'node:child_process';
import { find as windows } from '../host/windows.mjs';
const root = resolve(dirname(filename(import.meta.url)), '../..');
const vendor = join(root, 'vendor');
const lock = JSON.parse(read(join(vendor, 'manifest.json'), 'utf8'));
if (lock.format !== 'foo.vendor' || lock.version !== 1) throw Error('Unsupported vendor lock');
let count = 0;
function walk(directory) {
  for (const item of entries(directory, { withFileTypes: true })) {
    const path = join(directory, item.name);
    if (item.isSymbolicLink()) throw Error(`Uncontrolled vendor symlink: ${path}`);
    if (item.isDirectory()) walk(path);
    else {
      const name = relative(vendor, path).replaceAll('\\', '/');
      if (name === 'manifest.json') continue;
      if (!lock.files[name]) throw Error(`Unrecorded vendor file: ${name}`);
      const actual = hasher('sha256').update(read(path)).digest('hex');
      if (actual !== lock.files[name]) throw Error(`Vendor checksum mismatch: ${name}`);
      count++;
    }
  }
}
walk(vendor);
if (count !== Object.keys(lock.files).length) throw Error('Vendor files missing');
for (const dep of lock.dependencies) {
  if (!dep.license || !dep.version || !dep.url || !dep.notices.length || (!dep.revision && !dep.archiveSha256)) throw Error(`Missing provenance: ${dep.name}`);
  for (const notice of dep.notices) if (!exists(join(vendor, notice))) throw Error(`Missing license/copyright notice: ${notice}`);
}
// Known normal-build acquisition paths must remain absent. Developer bootstrap
// code is explicitly excluded; this audit itself has no network operations.
for (const file of ['src/toolchain/native.nim','src/build/project.nim','src/test/runner.nim']) {
  if (!exists(join(root,file))) continue; // Packaged compiler already embeds these source paths.
  const source = read(join(root,file),'utf8');
  if (/apt-get|apt-cache|dpkg-deb|\bfetch\s*\(/.test(source)) throw Error(`Offline build acquisition path: ${file}`);
  if (/\binstall\s*\(/.test(source)) throw Error(`Automatic toolchain provisioning: ${file}`);
}
if (process.argv.includes('--artifacts')) {
  for (const [path, symbol] of [['libsodium/windows-x64/libsodium.lib','sodium_init'],['zlib/windows-x64/zlib.lib','deflateInit_']]) {
    const file = join(vendor,path);
    const inspector = windows('dumpbin.exe', process.env.FOO_BINARY_INSPECTOR);
    const headers = invoke(inspector,['/headers',file],{encoding:'utf8',windowsHide:true,maxBuffer:32*1024*1024});
    const symbols = invoke(inspector,['/symbols',file],{encoding:'utf8',windowsHide:true,maxBuffer:32*1024*1024});
    if (headers.status !== 0 || !/machine \(x64\)/i.test(headers.stdout) || /machine \(x86\)/i.test(headers.stdout)) throw Error(`Invalid archive architecture: ${path}`);
    if (symbols.status !== 0 || !symbols.stdout.includes(symbol)) throw Error(`Missing ABI symbol ${symbol}: ${path}`);
  }
}
console.log(`Vendor audit passed: ${lock.dependencies.length} dependencies, ${count} SHA-256 locked files; offline normal build paths.`);
