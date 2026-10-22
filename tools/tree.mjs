import { readdirSync as entries } from 'node:fs';
import { join } from 'node:path';

const ignored = new Set(['.artifacts', '.foo', '.git', 'node_modules']);

export function files(directory, extension = '') {
  const result = [];
  function visit(directory) {
    for (const entry of entries(directory, { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
      if (ignored.has(entry.name)) continue;
      const path = join(directory, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.isFile() && entry.name.endsWith(extension)) result.push(path);
    }
  }
  visit(directory);
  return result;
}
