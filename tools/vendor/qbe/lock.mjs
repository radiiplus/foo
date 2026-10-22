import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const vendor = join(root, 'vendor');
const source = join(vendor, 'qbe');
const manifest = join(vendor, 'manifest.json');
const lock = JSON.parse(readFileSync(manifest, 'utf8'));
if (!lock.dependencies.some(item => item.name === 'qbe'))
  throw Error('QBE provenance is missing from the vendor manifest');

for (const path of Object.keys(lock.files))
  if (path.startsWith('qbe/')) delete lock.files[path];
function visit(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw Error(`QBE source contains a symlink: ${path}`);
    if (entry.isDirectory()) visit(path);
    else {
      const name = relative(vendor, path).replaceAll('\\', '/');
      lock.files[name] = createHash('sha256').update(readFileSync(path)).digest('hex');
    }
  }
}
visit(source);
writeFileSync(manifest, JSON.stringify(lock, null, 2) + '\n');
console.log(`Locked ${Object.keys(lock.files).filter(path => path.startsWith('qbe/')).length} QBE source files`);
