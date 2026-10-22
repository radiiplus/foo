import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { plan as nativePlan } from './native/plan.mjs';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const regions = JSON.parse(readFileSync(join(root, 'test/regions.json'), 'utf8'));
const order = regions.order;

function matches(path, patterns) {
  return patterns.some(pattern => path === pattern || path.startsWith(pattern));
}

function validateMap() {
  if (regions.format !== 'foo.test-regions.v1' || !order.length ||
      new Set(order).size !== order.length) throw Error('Invalid region map');
  for (const region of order) {
    if (!regions.regions[region]) throw Error(`Missing region definition: ${region}`);
    for (const dependency of regions.regions[region].depends)
      if (!order.includes(dependency) || dependency === region)
        throw Error(`Invalid region dependency: ${region} -> ${dependency}`);
  }
  for (const rule of regions.nativeOwners)
    if (!order.includes(rule.region) || !rule.paths.length) throw Error('Invalid native owner rule');
  for (const script of regions.scripts)
    if (!order.includes(script.region) || !existsSync(join(root, script.id)))
      throw Error(`Invalid regional script: ${script.id}`);
  if (new Set(regions.scripts.map(script => script.id)).size !== regions.scripts.length)
    throw Error('Duplicate regional script ID');
}
validateMap();

export function catalog() {
  const native = nativePlan(root, { noBatching: true }).units.map(unit => {
    const id = unit.name;
    const owner = regions.nativeOwners.find(rule => matches(id, rule.paths))?.region;
    if (!owner) throw Error(`Unowned native leaf: test/${id}`);
    return { id: `test/${id}`, path: id, region: owner, kind: 'native' };
  });
  const inventory = JSON.parse(readFileSync(join(root, 'test/inventory.json'), 'utf8'));
  const fixtures = inventory.entries.filter(entry => entry.path.startsWith('test/library/') &&
    entry.path.endsWith('.iv') && (entry.fooTestsInSource > 0 ||
      /^start\s*\{/m.test(readFileSync(join(root, entry.path), 'utf8'))))
    .map(entry => entry.path);
  if (!fixtures.length) throw Error('No semantic fixtures in the test inventory');
  return { native, fixtures, scripts: regions.scripts };
}

export function changedFiles(base = 'HEAD') {
  if (!/^[A-Za-z0-9_./~^+-]+$/.test(base) || base.startsWith('-'))
    throw Error(`Invalid git base: ${base}`);
  const tracked = execFileSync('git', ['diff', '--name-only', base, '--'],
    { cwd: root, encoding: 'utf8' }).split(/\r?\n/);
  const untracked = execFileSync('git', ['ls-files', '--others', '--exclude-standard'],
    { cwd: root, encoding: 'utf8' }).split(/\r?\n/);
  return [...new Set([...tracked, ...untracked].filter(Boolean).map(path => path.replaceAll('\\', '/')))].sort();
}

export function impact(files, items = catalog()) {
  if (!files.length) throw Error('No changed files selected');
  const reasons = new Map();
  const add = (region, reason) => {
    const entries = reasons.get(region) ?? new Set();
    const before = entries.size;
    entries.add(reason);
    reasons.set(region, entries);
    return entries.size !== before;
  };
  const native = new Map(items.native.map(item => [item.id, item.region]));
  const scripts = new Map(items.scripts.map(item => [item.id, item.region]));
  for (const file of files) {
    const path = file.replaceAll('\\', '/');
    const rules = regions.impact.filter(rule => matches(path, rule.paths));
    const direct = native.get(path) ?? scripts.get(path);
    if (direct) add(direct, `changed ${path}`);
    if (items.fixtures.includes(path)) add('core', `changed ${path}`);
    for (const rule of rules) for (const region of rule.regions) add(region, `changed ${path}`);
    if (!direct && !rules.length && !items.fixtures.includes(path))
      for (const region of order) add(region, `unmapped ${path}`);
  }
  let expanded = true;
  while (expanded) {
    expanded = false;
    for (const region of order.filter(name => reasons.has(name)))
      for (const dependency of regions.regions[region].depends)
        expanded = add(dependency, `dependency of ${region}`) || expanded;
  }
  return reasons;
}

export function selection(names, { mode = '', files = [] } = {}) {
  const items = catalog();
  let reasons;
  if (names.length === 1 && names[0] === 'changed') reasons = impact(files, items);
  else {
    if (names.length !== 1 || !order.includes(names[0])) throw Error(`Choose a region: ${order.join(', ')}, changed`);
    reasons = new Map([[names[0], new Set([`requested ${names[0]}`])]]);
  }
  const selected = [];
  for (const region of order.filter(name => reasons.has(name))) {
    const reason = [...reasons.get(region)].sort().join('; ');
    for (const item of items.native.filter(item => item.region === region))
      selected.push({ id: item.id, region, kind: 'native', reason });
    if (region === 'core') for (const fixture of items.fixtures) {
      for (const chosen of mode ? [mode] : ['dev', 'release'])
        selected.push({ id: `${fixture}@${chosen}`, region, kind: 'matrix', reason });
    }
    for (const script of items.scripts.filter(item => item.region === region && item.kind !== 'matrix'))
      selected.push({ id: script.id, region, kind: 'script', reason });
  }
  if (!selected.length) throw Error('Empty regional selection');
  if (new Set(selected.map(item => item.id)).size !== selected.length)
    throw Error('Duplicate regional leaf ID');
  return { regions: order.filter(name => reasons.has(name)), selected, scripts: items.scripts };
}
