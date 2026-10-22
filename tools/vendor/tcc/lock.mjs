import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const vendor = join(root, 'vendor');
const source = join(vendor, 'tcc');
const manifest = join(vendor, 'manifest.json');
const original = readFileSync(manifest, 'utf8');
const lock = JSON.parse(original);
if (!lock.dependencies.some(item => item.name === 'tinycc'))
  throw Error('TinyCC provenance is missing from the vendor manifest');

for (const path of Object.keys(lock.files))
  if (path.startsWith('tcc/')) delete lock.files[path];
function visit(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw Error(`TinyCC source contains a symlink: ${path}`);
    if (entry.isDirectory()) visit(path);
    else {
      const name = relative(vendor, path).replaceAll('\\', '/');
      lock.files[name] = createHash('sha256').update(readFileSync(path)).digest('hex');
    }
  }
}
visit(source);
const newline = original.includes('\r\n') ? '\r\n' : '\n';
writeFileSync(manifest, JSON.stringify(lock, null, 2).replaceAll('\n', newline) + newline);
console.log(`Locked ${Object.keys(lock.files).filter(path => path.startsWith('tcc/')).length} TinyCC source files`);
