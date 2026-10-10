import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import tm from 'vscode-textmate';
import onig from 'vscode-oniguruma';

const require = createRequire(import.meta.url);
const manifest = JSON.parse(readFileSync(new URL('../../editors/textmate/package.json', import.meta.url), 'utf8'));
const rules = manifest.contributes.configurationDefaults['editor.tokenColorCustomizations'].textMateRules;
for (const rule of rules) for (const scope of rule.scope) assert(scope.startsWith('source.foo '), `Color override leaks outside FOO: ${scope}`);
for (const scope of Object.keys(manifest.contributes.configurationDefaults['editor.semanticTokenColorCustomizations'].rules)) assert(scope.endsWith(':foo'));
const path = new URL('../../editors/textmate/grammars/foo.json', import.meta.url);
const raw = tm.parseRawGrammar(readFileSync(path, 'utf8'), path.pathname);
await onig.loadWASM(readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm')));
const registry = new tm.Registry({
  theme: { settings: [{ settings: { foreground: '#D4D4D4', background: '#1E1E1E' } },
    { scope: ['storage.type.foo', 'storage.modifier.type.foo', 'support.type.primitive.foo', 'entity.name.function.foo', 'constant.numeric.foo'], settings: { foreground: '#123456' } },
    ...rules] },
  onigLib: Promise.resolve({ createOnigScanner: patterns => new onig.OnigScanner(patterns), createOnigString: text => new onig.OnigString(text) }),
  loadGrammar: async scope => scope === 'source.control' ? { ...raw, scopeName: scope } : raw,
});
const grammar = await registry.loadGrammar('source.foo');
const colors = registry.getColorMap();
const checks = [
  ['function identity[T](value of type T) {', { function: '#FFD23F', identity: '#FF7043', T: '#39FF88', value: '#D4D4D4', of: '#FF3CAC', type: '#FFD23F' }],
  ['give value.', { give: '#F15BB5', value: '#D4D4D4' }],
  ['data of type pointer to byte.', { data: '#D4D4D4', of: '#FF3CAC', type: '#FFD23F', pointer: '#FFD23F', to: '#FF3CAC', byte: '#39FF88' }],
  ['constant limit is 42.', { constant: '#FFD23F', limit: '#D66BFF', is: '#FF79C6', '42': '#B6FF00' }],
  ['constant population is 1`000`000.', { '1`000`000': '#B6FF00' }],
  ['dynamic count is limit.', { dynamic: '#FFD23F', count: '#D4D4D4', limit: '#D4D4D4' }],
  ['define UserID as integer.', { define: '#FFD23F', UserID: '#39FF88', as: '#FFD23F', integer: '#39FF88' }],
  ['function greet name text punctuation text default "!" giving text {', { function: '#FFD23F', greet: '#FF7043', name: '#D4D4D4', text: '#39FF88', default: '#FFD23F', giving: '#FFD23F', '!': '#00E5FF' }],
  ['constant users are source fallback empty.', { constant: '#FFD23F', users: '#D66BFF', are: '#FF79C6', fallback: '#FF79C6' }],
  ['measure try.', { measure: '#FF7043', try: '#F15BB5' }],
  ['constant item of type core.reference is uninitialized.', { of: '#FF3CAC', type: '#FFD23F', reference: '#39FF88' }],
  ['match item { case anything {', { match: '#C792EA', case: '#C792EA' }],
  ['after { release item. }', { after: '#7DF9FF' }],
  ['increase count by 1.', { increase: '#FF79C6', by: '#FF79C6', '1': '#B6FF00' }],
  ['give data.length plus data.front().', { length: '#8BD3FF', front: '#FF7043', plus: '#FF79C6' }],
  ['give "hello" plus newline.', { hello: '#00E5FF', newline: '#D66BFF' }],
  ['give "bad\\q".', { '\\q': '#FF3864' }],
  ['give "unfinished', { unfinished: '#FF3864' }],
  ['-- ordinary comment', { ordinary: '#8A9099' }],
  ['--! Documentation', { Documentation: '#8FBCBB' }],
  ['#[packed]', { packed: '#C792EA' }],
  ['function boot for startup without setup using feature "sse2" keeping call {', { startup: '#FFD23F', without: '#FFD23F', setup: '#FFD23F', using: '#FFD23F', feature: '#FFD23F', sse2: '#00E5FF', keeping: '#FFD23F', call: '#FFD23F' }],
  ['data of type pointer to byte with exact access.', { with: '#FFD23F', exact: '#FFD23F', access: '#FFD23F' }],
  // These are not reserved FOO words. A palette must not invent syntax.
  ['from with into', { from: '#D4D4D4', with: '#D4D4D4', into: '#D4D4D4' }],
];
let count = 0;
for (const [source, expected] of checks) {
  const { tokens } = grammar.tokenizeLine2(source, tm.INITIAL);
  for (const [word, color] of Object.entries(expected)) {
    const start = source.indexOf(word);
    assert(start >= 0);
    for (let offset = start; offset < start + word.length; offset++) {
      let token = 0;
      while (token + 2 < tokens.length && tokens[token + 2] <= offset) token += 2;
      assert.equal(colors[(tokens[token + 1] >>> 15) & 0x1ff], color, `${source}: ${word}`);
    }
    count++;
  }
}
const other = await registry.loadGrammar('source.control');
const control = other.tokenizeLine2('pointer', tm.INITIAL).tokens;
assert.equal(registry.getColorMap()[(control[1] >>> 15) & 0x1ff], '#123456', 'Another language must retain its theme color even for the same token scope');
registry.dispose();
console.log(`Passed ${count} rendered theme color assertions, including invalid syntax and neutral unresolved references.`);
