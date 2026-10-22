import { files } from '../../tools/tree.mjs';
import { existsSync as exists, mkdirSync as mkdir, readFileSync as read, writeFileSync as write } from 'node:fs';
import { dirname, join, relative } from 'node:path';

// A suite is only a container: its imported leaf modules remain the coverage IDs.
export function plan(root, { noBatching: unbatched = false, filter = '', ids = null } = {}) {
  if (ids && filter) throw Error('Choose exact leaf IDs or a filter');
  const directory = join(root, 'test');
  const name = file => relative(directory, file).replaceAll('\\', '/');
  const discovered = files(directory, '.nim');
  discovered.sort();
  const active = discovered;
  const grouped = new Set();
  const containers = new Map();
  for (const file of active.filter(file => name(file).startsWith('suites/'))) {
    const source = read(file, 'utf8');
    const modules = [...source.matchAll(/^import (?:\.\.\/|"\.\.\/)([a-z/]+)"? as [a-z]+$/gm)]
      .map(match => match[1] + '.nim');
    if (!modules.length) throw Error(`Empty native suite: ${name(file)}`);
    if (source.split(/\r?\n/).filter(line => /^import\b/.test(line)).length !== modules.length)
      throw Error(`Uncounted native suite import: ${name(file)}; use explicit leaf imports with aliases`);
    for (const module of modules) {
      if (module.startsWith('suites/') || !exists(join(directory, module)) || grouped.has(module))
        throw Error(`Invalid or duplicate suite import: ${module}`);
      grouped.add(module);
    }
    containers.set(name(file), modules);
  }
  const leaves = new Set(active.map(name).filter(id => !containers.has(id)));
  if (ids) {
    if (!(ids instanceof Set) || ids.size === 0) throw Error('Empty native leaf selection');
    for (const id of ids) if (!leaves.has(id)) throw Error(`Unknown native leaf: ${id}`);
  }
  const units = [];
  const selected = new Map();
  if (!unbatched) for (const [id, modules] of containers) {
    const matched = modules.filter(module => ids ? ids.has(module) :
      !filter || id.includes(filter) || module.includes(filter));
    if (matched.length > 1) selected.set(id, matched);
  }
  for (const file of active) {
    const id = name(file);
    if (containers.has(id)) {
      if (selected.has(id))
        units.push({ file, name: id, modules: selected.get(id),
          fullSuite: selected.get(id).length === containers.get(id).length });
    } else if (![...selected.values()].some(modules => modules.includes(id)) &&
        (ids ? ids.has(id) : !filter || id.includes(filter))) {
      // A leaf filter compiles that leaf alone, avoiding unrelated suite work.
      units.push({ file, name: id, modules: [id] });
    }
  }
  return { units, groupedModules: grouped.size };
}

export function prepare(unit, output) {
  if (unit.modules.length === 1) return unit.file;
  const directory = join(output, 'units', unit.name.replace(/\.nim$/, '').replaceAll('/', '-'));
  mkdir(directory, { recursive: true });
  const imports = [];
  const root = dirname(dirname(unit.file));
  for (let index = 0; index < unit.modules.length; index++) {
    const wrapper = join(directory, `module${index}.nim`);
    const leaf = join(root, unit.modules[index]).replaceAll('\\', '/');
    write(wrapper, `import std/os\nimport ${JSON.stringify(leaf)} as leaf\n` +
      `echo "\\nFOO_NATIVE_MODULE|" & getEnv("FOOTESTID") & "|${unit.modules[index]}"\n`);
    imports.push(`import ${JSON.stringify(wrapper.replaceAll('\\', '/'))} as module${index}`);
  }
  // Preserve suite-local checks only when all of its leaves are selected.
  if (unit.fullSuite)
    imports.push(`import ${JSON.stringify(unit.file.replaceAll('\\', '/'))} as original`);
  const main = join(directory, 'main.nim');
  write(main, imports.join('\n') + '\n');
  return main;
}
