// Explicitly refresh the real-source corpus; ordinary tests never rewrite it.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const target = resolve(root, 'editors/textmate/test/cases');
mkdirSync(target, { recursive: true });
const sources = {
  declarations: 'docs/editors/naming.md',
  types: 'spec/advanced-types.md',
  interop: 'spec/c-interop.md',
  concurrency: 'spec/concurrency.md',
  control: 'tests/lex/fixtures/sample.rt',
  pointers: 'std/deque.rt',
  errors: 'std/crypto.rt',
  platforms: 'std/os/windows.rt',
  compiler: 'compiler/main.rt',
};
const provenance = {};
for (const [name, path] of Object.entries(sources)) {
  const source = readFileSync(resolve(root, path), 'utf8').replace(/\r\n?/g, '\n');
  const extracted = path.endsWith('.rt') ? source : [...source.matchAll(/```(?:rt|tratio)\n([\s\S]*?)\n```/g)].map(match => match[1]).join('\n\n') + '\n';
  const content = extracted.replace(/[ \t]+$/gm, '');
  if (!content.trim()) throw Error(`No Tratio examples in ${path}`);
  writeFileSync(join(target, `${name}.rt`), content);
  provenance[name] = { source: path, sourceSha256: createHash('sha256').update(source).digest('hex'), fixtureSha256: createHash('sha256').update(content).digest('hex') };
}
writeFileSync(join(target, 'sources.json'), JSON.stringify(provenance, null, 2) + '\n');
console.log(`Collected ${Object.keys(sources).length} real-source fixtures. Review and explicitly regenerate snapshots next.`);
