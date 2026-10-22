import { readFile } from 'node:fs/promises';

// 44
export async function version() {
  const compiler = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  return `FOO IV\ncompiler ${compiler.version}\nlanguage 1`;
}
