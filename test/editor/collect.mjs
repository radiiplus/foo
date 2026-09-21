// Explicitly refresh the real-source corpus; ordinary tests never rewrite it.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const target = resolve(root, 'test/editor/cases');
mkdirSync(target, { recursive: true });
const sources = {
  declarations: 'docs/editors/naming.md',
  types: 'specs/types.md',
  interop: 'specs/native.md',
  concurrency: 'specs/concurrency.md',
  control: 'test/lex/fixtures/sample.iv',
  pointers: 'std/deque.iv',
  errors: 'std/crypto.iv',
  platforms: 'std/os/windows.iv',
  library: ['std/sequence.iv', 'std/text.iv', 'test/stdlib/collections.iv', 'test/stdlib/services.iv'],
};
const selected = process.argv.slice(2);
if (selected.some(name => !Object.hasOwn(sources, name))) throw Error('Unknown fixture family');
const provenance = selected.length
  ? Object.fromEntries(Object.entries(JSON.parse(readFileSync(join(target, 'sources.json'), 'utf8'))).filter(([name]) => Object.hasOwn(sources, name)))
  : {};
for (const [name, input] of Object.entries(sources)) {
  if (selected.length && !selected.includes(name)) continue;
  const origins = [];
  const fragments = [];
  for (const path of [input].flat()) {
    const source = readFileSync(resolve(root, path), 'utf8').replace(/\r\n?/g, '\n');
    const extracted = path.endsWith('.iv') ? source : [...source.matchAll(/```(?:iv|foo)\n([\s\S]*?)\n```/g)].map(match => match[1]).join('\n\n') + '\n';
    if (!extracted.trim()) throw Error(`No FOO examples in ${path}`);
    fragments.push(Array.isArray(input) ? `-- Source: ${path}\n${extracted}` : extracted);
    origins.push({ source: path, sourceSha256: createHash('sha256').update(source).digest('hex') });
  }
  const extracted = fragments.join('\n');
  const content = (extracted.startsWith('--') ? extracted : `-- Exercises ${name} syntax.\n` + extracted).replace(/[ \t]+$/gm, '');
  writeFileSync(join(target, `${name}.iv`), content);
  provenance[name] = { ...(origins.length === 1 ? origins[0] : { sources: origins }), fixtureSha256: createHash('sha256').update(content).digest('hex') };
}
writeFileSync(join(target, 'sources.json'), JSON.stringify(provenance, null, 2) + '\n');
console.log(`Collected ${selected.length || Object.keys(sources).length} real-source fixtures. Review and explicitly regenerate snapshots next.`);
