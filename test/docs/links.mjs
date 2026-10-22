import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, extname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const required = ['AGENTS.md', 'CONTRIBUTING.md', 'README.md',
  'docs/POLICY.md', 'docs/README.md', 'specs/README.md', 'benchmark/POLICY.md'];
const errors = [];
for (const path of required) {
  if (!existsSync(resolve(root, path))) errors.push(`missing required file: ${path}`);
}
for (const path of ['AGENTS.md', 'CONTRIBUTING.md']) {
  if (existsSync(resolve(root, path)) &&
      !readFileSync(resolve(root, path), 'utf8').includes('docs/POLICY.md'))
    errors.push(`${path}: missing docs/POLICY.md reference`);
}

for (const entry of readdirSync(resolve(root, 'docs'), { withFileTypes: true })) {
  if (entry.isFile() && extname(entry.name).toLowerCase() === '.md' &&
      !/^[A-Za-z][A-Za-z0-9]*\.md$/.test(entry.name))
    errors.push(`docs/${entry.name}: user-guide filenames must be one word`);
}

const website = readFileSync(resolve(root, 'registry/ui/src/content/docs.ts'), 'utf8');
const book = readFileSync(resolve(root, 'docs/README.md'), 'utf8');
const sitemap = readFileSync(resolve(root, 'registry/ui/public/sitemap.xml'), 'utf8');
const imports = new Map([...website.matchAll(/^import (\w+) from "\.\.\/\.\.\/\.\.\/\.\.\/docs\/([^"/]+\.md)\?raw";/gm)]
  .map(([, variable, file]) => [file, variable]));
if (imports.has('POLICY.md') || /\{\s*id:\s*["']policy["']/.test(website))
  errors.push('docs/POLICY.md: policy must not appear as a website chapter');
if (book.includes('](POLICY.md)'))
  errors.push('docs/README.md: policy must not appear in the public book index');
const chapterIds = [...website.matchAll(/\{ id: "([a-z0-9-]+)"/g)].map((match) => match[1]);
const sitemapIds = [...sitemap.matchAll(/https:\/\/fooregistry\.web\.app\/docs\/([a-z0-9-]+)<\/loc>/g)]
  .map((match) => match[1]);
for (const id of chapterIds) {
  if (!sitemapIds.includes(id)) errors.push(`docs/${id}: missing website sitemap URL`);
}
for (const id of sitemapIds) {
  if (!chapterIds.includes(id)) errors.push(`docs/${id}: sitemap URL has no website chapter`);
}
for (const entry of readdirSync(resolve(root, 'docs'), { withFileTypes: true })) {
  if (!entry.isFile() || extname(entry.name).toLowerCase() !== '.md') continue;
  if (entry.name === 'POLICY.md') continue;
  const variable = imports.get(entry.name);
  if (!variable || !new RegExp(`\\bsource:\\s*${variable}\\b`).test(website))
    errors.push(`docs/${entry.name}: missing website chapter`);
  if (entry.name !== 'README.md' && !book.includes(`](${entry.name})`))
    errors.push(`docs/${entry.name}: missing book index link`);
}

function* walk(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (['.git', '.artifacts', 'footestlib', 'node_modules', 'output',
      'target-windows', 'vendor'].includes(entry.name) ||
      (directory === root && entry.name === 'release'))
      continue;
    const path = join(directory, entry.name);
    if (entry.isDirectory()) yield* walk(path);
    else if (entry.isFile() && extname(entry.name).toLowerCase() === '.md')
      yield path;
  }
}

let checked = 0;
for (const file of walk(root)) {
  let fenced = false;
  const lines = readFileSync(file, 'utf8').split(/\r?\n/);
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (/^\s*(```|~~~)/.test(line)) { fenced = !fenced; continue; }
    if (fenced) continue;
    for (const match of line.matchAll(/(?<![\w])!?\[[^\]]*\]\((<[^>]+>|[^\s)]+)(?:\s+"[^"]*")?\)/g)) {
      let target = match[1].replace(/^<|>$/g, '');
      if (/^(?:[a-z][a-z\d+.-]*:|#|\/\/)/i.test(target)) continue;
      target = decodeURIComponent(target.split('#', 1)[0]);
      if (!target) continue;
      const destination = resolve(dirname(file), target);
      const label = file.slice(root.length + 1).split(sep).join('/');
      checked++;
      if (!existsSync(destination))
        errors.push(`${label}:${index + 1}: missing link target ${target}`);
    }
  }
}

if (errors.length) {
  for (const error of errors) console.error(error);
  process.exitCode = 1;
} else {
  console.log(`Documentation links: ${checked} local targets found`);
}
