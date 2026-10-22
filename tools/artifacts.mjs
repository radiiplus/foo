import { randomUUID } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const marker = 'foo.artifact-run.v1';
const categories = new Set(['build', 'test', 'bench', 'release', 'tools']);

export function base() {
  return resolve(process.env.FOO_ARTIFACT_ROOT || join(repository, '.artifacts'));
}

export function path(...parts) {
  if (parts.some(part => typeof part !== 'string' || !part || part === '.' || part === '..' ||
      isAbsolute(part) || part.includes('/') || part.includes('\\')))
    throw Error('Artifact path components must be simple names');
  return join(base(), ...parts);
}

export function create(category, { outputs = ['.'] } = {}) {
  if (!categories.has(category)) throw Error(`Unknown artifact category: ${category}`);
  const root = base();
  if (existsSync(root) && lstatSync(root).isSymbolicLink())
    throw Error(`Artifact root is a link: ${root}`);
  const parent = path(category);
  mkdirSync(parent, { recursive: true });
  if (lstatSync(root).isSymbolicLink() || lstatSync(parent).isSymbolicLink())
    throw Error(`Artifact category is a link: ${parent}`);
  const directory = join(parent, `run-${randomUUID()}`);
  mkdirSync(directory);
  writeFileSync(join(directory, 'manifest.json'), JSON.stringify({ format: marker,
    category, pid: process.pid, created: new Date().toISOString(), outputs }, null, 2) + '\n');
  return directory;
}

function size(path) {
  const entry = lstatSync(path);
  if (entry.isSymbolicLink()) throw Error(`Refusing linked artifact: ${path}`);
  if (!entry.isDirectory()) return entry.size;
  return readdirSync(path).reduce((total, name) => total + size(join(path, name)), 0);
}

function alive(pid) {
  if (!Number.isInteger(pid) || pid < 1) return true;
  try { process.kill(pid, 0); return true; }
  catch (error) { return error.code !== 'ESRCH'; }
}

export function clean({ all = false, dryRun = false } = {}) {
  if (!all && !dryRun) throw Error('Choose --dry-run or --all');
  const root = base();
  if (!existsSync(root)) return { root, candidates: [], skipped: [] };
  if (lstatSync(root).isSymbolicLink()) throw Error(`Artifact root is a link: ${root}`);
  const canonical = realpathSync(root);
  const candidates = [];
  const skipped = [];
  for (const category of readdirSync(root)) {
    const parent = join(root, category);
    if (!lstatSync(parent).isDirectory() || lstatSync(parent).isSymbolicLink()) continue;
    for (const name of readdirSync(parent)) {
      if (!name.startsWith('run-')) continue;
      const directory = join(parent, name);
      if (!lstatSync(directory).isDirectory() || lstatSync(directory).isSymbolicLink()) {
        skipped.push({ directory, reason: 'not a real directory' });
        continue;
      }
      const path = relative(canonical, realpathSync(directory));
      if (path.startsWith('..' + sep) || path === '..' || isAbsolute(path))
        throw Error(`Artifact escapes its root: ${directory}`);
      let manifest;
      try { manifest = JSON.parse(readFileSync(join(directory, 'manifest.json'), 'utf8')); }
      catch { skipped.push({ directory, reason: 'missing manifest' }); continue; }
      if (manifest.format !== marker || manifest.category !== category) {
        skipped.push({ directory, reason: 'unowned directory' });
        continue;
      }
      if (alive(manifest.pid)) { skipped.push({ directory, reason: 'live process' }); continue; }
      const bytes = size(directory);
      candidates.push({ directory, bytes });
      if (all && !dryRun) rmSync(directory, { recursive: true });
    }
  }
  return { root, candidates, skipped };
}
