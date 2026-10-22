import { existsSync as exists, readFileSync as read, writeFileSync as write } from 'node:fs';
import { files } from './tree.mjs';
import { createHash as hasher } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { spawnSync as invoke } from 'node:child_process';
import { find as windows } from './host/windows.mjs';

// Discover literal compile-time inputs rather than maintaining a second list.
export function embedded(root) {
  const inputs = new Set();
  for (const file of files(join(root, 'src'), '.nim')) {
    const source = read(file, 'utf8');
    for (const match of source.matchAll(/\bstaticRead\s*\(\s*"([^"\r\n]+)"\s*\)/g)) {
      const input = resolve(dirname(file), match[1]);
      if (!exists(input)) throw Error(`Missing staticRead input ${match[1]} in ${file}`);
      inputs.add(input);
    }
  }
  return [...inputs].sort();
}

export function compile({ root, cache, compiler = process.env.FOO_RESOURCE_COMPILER || 'rc.exe', force = false }) {
  const executable = windows('rc.exe', compiler === 'rc.exe' ? '' : compiler);
  const source = join(root, 'installers/windows/foo.rc');
  const resource = resolve(cache, 'foo.res');
  const stamp = resolve(cache, 'resource.json');
  const script = read(source, 'utf8');
  const lines = script.replace(/\/\*[\s\S]*?\*\/|\/\/[^\r\n]*/g, '').split(/\r?\n/).map(line => line.trim()).filter(Boolean);
  const icons = lines.map(line => line.match(/^(?:[A-Za-z_]\w*|\d+)\s+ICON\s+"([^"]+)"$/)).filter(Boolean)
    .map(match => resolve(dirname(source), match[1]));
  // Cache only the literal ICON/constant-ID grammar whose inputs we can prove.
  // Includes, version resources and other extensions use the compiler each time.
  const reusable = icons.length > 0 && lines.every(line => /^(?:[A-Za-z_]\w*|\d+)\s+ICON\s+"[^"]+"$/.test(line) ||
    /^#\s*define\s+[A-Za-z_]\w*\s+(?:\d+|0x[0-9a-fA-F]+)$/.test(line));
  const digest = hasher('sha256');
  for (const file of [source, ...icons, executable])
    digest.update(file).update('\0').update(read(file)).update('\0');
  const identity = digest.digest('hex');
  const checksum = () => hasher('sha256').update(read(resource)).digest('hex');
  let receipt;
  try { receipt = JSON.parse(read(stamp, 'utf8')); } catch {}
  const hit = reusable && !force && exists(resource) && receipt?.identity === identity && receipt.output === checksum();
  if (!hit) {
    const result = invoke(executable, ['/FO', resource, source], {
      cwd: dirname(source), stdio: 'inherit', windowsHide: true,
    });
    if (result.error || result.status !== 0) throw Error(result.error?.message || `Resource compilation failed with exit ${result.status}`);
    write(stamp, JSON.stringify({ identity, output: checksum() }) + '\n');
  }
  return { resource, hit };
}
