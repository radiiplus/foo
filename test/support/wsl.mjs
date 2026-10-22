import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { files } from '../../tools/tree.mjs';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const directQbeCallers = new Map([
  ['src/backend/qbe/driver.nim', 3],
  ['test/backend/qbe/scripts/qualification.mjs', 1],
  ['test/backend/qbe/riscv/board.mjs', 2],
  ['test/backend/qbe/scripts/uefi-boot.mjs', 1],
  ['test/backend/qbe/scripts/wasi-threads.mjs', 1],
]);
export function auditWsl(base = root) {
  const observed = new Map();
  for (const directory of ['src', 'test', 'tools', 'bin', 'benchmark', 'installers']) {
    if (!existsSync(resolve(base, directory))) continue;
    for (const file of files(resolve(base, directory))) {
      if (!/\.(?:nim|mjs|ps1)$/.test(file) || file === fileURLToPath(import.meta.url)) continue;
      const path = file.slice(base.length + 1).replaceAll('\\', '/');
      if (path === 'tools/wsl.mjs') continue;
      const calls = readFileSync(file, 'utf8').match(/\bwsl\.exe\b|&\s+wsl\b/g) ?? [];
      if (calls.length) observed.set(path, calls.length);
    }
  }
  for (const [path, count] of observed)
    if (directQbeCallers.get(path) !== count)
      throw Error(`Unreviewed direct WSL caller: ${path} (${count})`);
  return { directCallers: observed.size };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  console.log(JSON.stringify(auditWsl()));
