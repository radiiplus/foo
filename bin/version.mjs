import { readFile } from 'node:fs/promises';

// 44
export async function version() {
  const [compiler, project] = await Promise.all([
    readFile(new URL('../package.json', import.meta.url), 'utf8').then(JSON.parse),
    readFile(new URL('../project.json', import.meta.url), 'utf8').then(JSON.parse),
  ]);
  return `FOO IV\ncompiler ${compiler.version}\nlanguage ${project.language}`;
}
