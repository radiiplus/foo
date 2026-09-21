import { mkdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

export function temporary() {
  const path = resolve(dirname(fileURLToPath(import.meta.url)), '../.artifacts/test');
  mkdirSync(path, { recursive: true });
  return path;
}
