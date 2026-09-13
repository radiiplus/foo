import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import tm from 'vscode-textmate';
import onig from 'vscode-oniguruma';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const update = process.argv.includes('--update');
assert(!(update && process.env.CI), 'CI must never rewrite scope assertions');
const override = process.argv.find(value => value.startsWith('--cases='));
const directory = override ? resolve(override.slice(8)) : join(root, 'test/cases');
const provenance = JSON.parse(readFileSync(join(directory, 'sources.json'), 'utf8'));
await onig.loadWASM(readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm')));
const path = join(root, 'grammars/tratio.tmLanguage.json');
const registry = new tm.Registry({
  onigLib: Promise.resolve({ createOnigScanner: patterns => new onig.OnigScanner(patterns), createOnigString: text => new onig.OnigString(text) }),
  loadGrammar: async scope => scope === 'source.tratio' ? tm.parseRawGrammar(readFileSync(path, 'utf8'), path) : null,
});
const grammar = await registry.loadGrammar('source.tratio');
let lines = 0, tokens = 0;
const names = readdirSync(directory).filter(name => name.endsWith('.rt')).sort();
assert(names.includes('compiler.rt'), 'Missing complex compiler fixture');
assert.equal(names.length, Object.keys(provenance).length, 'Fixture/provenance inventory differs');
for (const name of names) {
  const source = readFileSync(join(directory, name), 'utf8').replace(/\r\n?/g, '\n');
  const metadata = provenance[name.slice(0, -3)];
  assert(metadata, `Missing provenance for ${name}`);
  assert.equal(createHash('sha256').update(source).digest('hex'), metadata.fixtureSha256, `Fixture changed without provenance update: ${name}`);
  const text = source.replace(/\n$/, '').split('\n');
  if (name === 'compiler.rt') assert(text.length >= 200, 'Complex fixture must have at least 200 lines');
  let state = tm.INITIAL;
  const actual = text.map(line => {
    const result = grammar.tokenizeLine(line, state, 1000);
    assert(!result.stoppedEarly, `${name}: tokenization timed out`);
    state = result.ruleStack;
    tokens += result.tokens.length;
    return { line, tokens: result.tokens.map(token => [token.startIndex, token.endIndex, token.scopes.join(' ')]) };
  });
  lines += actual.length;
  const assertion = join(directory, name.replace(/\.rt$/, '.json'));
  if (update) writeFileSync(assertion, '[\n' + actual.map(row => '  ' + JSON.stringify(row)).join(',\n') + '\n]\n');
  else {
    const expected = JSON.parse(readFileSync(assertion, 'utf8'));
    assert.equal(actual.length, expected.length, `${name}: line count changed`);
    for (let index = 0; index < actual.length; index++) assert.deepEqual(actual[index], expected[index], `${name}:${index + 1}: scope snapshot mismatch`);
  }
}
registry.dispose();
console.log(`${update ? 'Updated' : 'Passed'} ${names.length} full-file snapshots: ${lines} lines, ${tokens} tokens.`);
