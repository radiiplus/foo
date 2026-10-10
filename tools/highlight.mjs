import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import onig from 'vscode-oniguruma';
import tm from 'vscode-textmate';

const require = createRequire(import.meta.url);
const root = new URL('../', import.meta.url);
const readme = new URL('README.md', root);
const manifest = JSON.parse(readFileSync(new URL('editors/textmate/package.json', root), 'utf8'));
const grammarfile = new URL('editors/textmate/grammars/foo.json', root);
const raw = tm.parseRawGrammar(readFileSync(grammarfile, 'utf8'), grammarfile.pathname);
const rules = manifest.contributes.configurationDefaults['editor.tokenColorCustomizations'].textMateRules;
const foreground = '#D4D4D4';
const background = '#1E1E1E';

await onig.loadWASM(readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm')));

const registry = new tm.Registry({
  theme: {
    settings: [
      { settings: { foreground, background } },
      ...rules,
    ],
  },
  onigLib: Promise.resolve({
    createOnigScanner: patterns => new onig.OnigScanner(patterns),
    createOnigString: value => new onig.OnigString(value),
  }),
  loadGrammar: async scope => scope === 'source.foo' ? raw : null,
});

const grammar = await registry.loadGrammar('source.foo');
if (!grammar) throw new Error('Unable to load the FOO TextMate grammar.');

const source = readFileSync(readme, 'utf8');
const examples = [...source.matchAll(/<!-- highlight:([a-z][a-z0-9]*) -->[\s\S]*?```foo\r?\n([\s\S]*?)\r?\n```/g)];
if (examples.length === 0) throw new Error('README.md contains no marked FOO examples.');

const output = new URL('assets/readme/', root);
mkdirSync(output, { recursive: true });
const colors = registry.getColorMap();

for (const match of examples) {
  const [, name, code] = match;
  writeFileSync(new URL(`${name}.svg`, output), render(name, code));
}

registry.dispose();
console.log(`Rendered ${examples.length} README FOO examples with the extension theme.`);

function render(name, code) {
  const lines = code.replaceAll('\t', '    ').split(/\r?\n/);
  const padding = 20;
  const size = 15;
  const leading = 24;
  const width = Math.max(640, padding * 2 + Math.max(...lines.map(line => line.length)) * 9);
  const height = padding * 2 + lines.length * leading;
  const rendered = [];
  let stack = tm.INITIAL;

  for (let line = 0; line < lines.length; line++) {
    const value = lines[line];
    const result = grammar.tokenizeLine2(value, stack);
    stack = result.ruleStack;
    const segments = [];

    for (let token = 0; token < result.tokens.length; token += 2) {
      const start = result.tokens[token];
      const end = token + 2 < result.tokens.length ? result.tokens[token + 2] : value.length;
      const color = colors[(result.tokens[token + 1] >>> 15) & 0x1ff] ?? foreground;
      const content = value.slice(start, end);
      if (content) segments.push(`<tspan fill="${escape(color)}">${escape(content)}</tspan>`);
    }

    rendered.push(`  <text x="${padding}" y="${padding + size + line * leading}">${segments.join('')}</text>`);
  }

  const title = `${name[0].toUpperCase()}${name.slice(1)} FOO source example`;
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="title">`,
    `  <title id="title">${escape(title)}</title>`,
    `  <rect x="0.5" y="0.5" width="${width - 1}" height="${height - 1}" rx="6" fill="${background}" stroke="#343A40"/>`,
    `  <g fill="${foreground}" font-family="Cascadia Code, SFMono-Regular, Consolas, Liberation Mono, monospace" font-size="${size}" xml:space="preserve">`,
    ...rendered,
    '  </g>',
    '</svg>',
    '',
  ].join('\n');
}

function escape(value) {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}
