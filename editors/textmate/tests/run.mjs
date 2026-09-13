import assert from 'node:assert/strict';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import tm from 'vscode-textmate';
import onig from 'vscode-oniguruma';

const require = createRequire(import.meta.url);
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
const contribution = manifest.contributes.grammars[0];
assert.equal(contribution.language, 'tratio');
assert.equal(contribution.scopeName, 'source.tratio');
assert.deepEqual(manifest.contributes.languages[0].extensions, ['.rt']);
const path = resolve(root, contribution.path);
const raw = tm.parseRawGrammar(readFileSync(path, 'utf8'), path);
assert.equal(raw.scopeName, contribution.scopeName);
await onig.loadWASM(readFileSync(require.resolve('vscode-oniguruma/release/onig.wasm')));
let expressions = 0;
function visit(value) {
  if (!value || typeof value !== 'object') return;
  for (const [key, item] of Object.entries(value)) {
    if (['begin', 'end', 'match', 'while'].includes(key) && typeof item === 'string') {
      const scanner = new onig.OnigScanner([item]);
      scanner.dispose();
      expressions++;
    } else if (key === 'include') {
      assert(item === '$self' || (item.startsWith('#') && raw.repository[item.slice(1)]), `Unresolved include: ${item}`);
    } else visit(item);
  }
}
visit(raw);
const registry = new tm.Registry({
  onigLib: Promise.resolve({ createOnigScanner: patterns => new onig.OnigScanner(patterns), createOnigString: text => new onig.OnigString(text) }),
  loadGrammar: async scope => scope === raw.scopeName ? raw : null,
});
const grammar = await registry.loadGrammar(raw.scopeName);
assert(grammar);
function tokenize(source) {
  let state = tm.INITIAL;
  return source.replace(/\r\n?/g, '\n').split('\n').map(line => {
    const result = grammar.tokenizeLine(line, state, 1000);
    assert(!result.stoppedEarly, `Tokenization timed out: ${line.slice(0, 80)}`);
    state = result.ruleStack;
    return { line, tokens: result.tokens };
  });
}
let assertions = 0;
const pointer = tokenize(readFileSync(join(root, 'test/cases/pointers.rt'), 'utf8')).find(row => row.line.includes('data of type pointer to byte.'));
assert(pointer, 'Missing real pointer declaration fixture');
for (const [text, scope] of [['of type', 'meta.type.annotation.tratio'], ['pointer', 'storage.modifier.type.tratio'], ['to', 'meta.type.annotation.tratio'], ['byte', 'support.type.primitive.tratio']]) {
  const start = pointer.line.indexOf(text);
  const tokens = pointer.tokens.filter(token => token.startIndex < start + text.length && token.endIndex > start);
  assert(tokens.length && tokens.every(token => token.scopes.includes(scope)), `${text} must use ${scope}`);
  assertions++;
}
const configuration = JSON.parse(readFileSync(join(root, 'language-configuration.json'), 'utf8'));
const increase = new RegExp(configuration.indentationRules.increaseIndentPattern);
const decrease = new RegExp(configuration.indentationRules.decreaseIndentPattern);
for (const line of ['module app {', '  function visit() {', '  } otherwise {']) assert(increase.test(line), `Block must indent: ${line}`);
for (const line of ['-- comment {', '--- comment {', 'constant brace is "{".', 'function empty() {}']) assert(!increase.test(line), `Unexpected indentation: ${line}`);
assert(decrease.test('  } otherwise {'));
assert.equal('data.value'.match(new RegExp(configuration.wordPattern, 'g')).join(','), 'data,value');
assert.deepEqual(configuration.comments, { lineComment: '--', blockComment: ['---', '---'] });
assert(!manifest.contributes.configuration && !manifest.contributes.themes && !manifest.contributes.iconThemes && !manifest.main, 'Extension must remain declarative and expose no settings/theme/LSP');
for (const variant of ['light', 'dark']) assert.match(readFileSync(resolve(root, manifest.contributes.languages[0].icon[variant]), 'utf8'), /<svg\b/);
for (const name of ['keywords', 'forms']) {
  const source = readFileSync(join(root, `tests/fixtures/${name}.rt`), 'utf8');
  const rows = tokenize(source);
  const checks = JSON.parse(readFileSync(join(root, `tests/fixtures/${name}.json`), 'utf8'));
  for (const check of checks) {
    const row = rows[check.line - 1];
    const start = check.last ? row.line.lastIndexOf(check.text) : row.line.indexOf(check.text);
    assert(start >= 0, `Missing fixture text: ${name}:${check.line} ${check.text}`);
    const tokens = row.tokens.filter(token => token.endIndex > start && token.startIndex < start + check.text.length);
    assert(tokens.length > 0);
    for (const token of tokens) {
      const context = `${name}:${check.line} ${JSON.stringify(check.text)}: ${token.scopes.join(' ')}`;
      if (check.scope) assert(token.scopes.includes(check.scope), `Expected ${check.scope}; ${context}`);
      if (check.absent) assert(!token.scopes.includes(check.absent), `Unexpected ${check.absent}; ${context}`);
    }
    assertions++;
  }
}
// Check coverage against the compiler when running in the Tratio checkout.
// The standalone grammar package does not require the compiler to run tests.
const lexer = resolve(root, '../../src/lex/lexer.ts');
if (existsSync(lexer)) {
  const source = readFileSync(lexer, 'utf8');
  const table = source.match(/const keywords: Record<string, Kind> = \{([\s\S]*?)\n    \};/);
  assert(table, 'Cannot find compiler keyword table; update the coverage check.');
  const keywords = [...table[1].matchAll(/\b([a-z_]+): Kind\./g)].map(match => match[1]);
  const fixtures = readFileSync(join(root, 'tests/fixtures/keywords.rt'), 'utf8').split(/\r?\n/);
  for (const word of keywords) assert(fixtures.includes(word), `Compiler keyword lacks a fixture line: ${word}`);
  console.log(`Covered all ${keywords.length} compiler keywords, plus contextual words.`);
}
// Large unterminated lines and EOF recovery exercise the regex engine itself.
for (const source of ['"', "'", '"' + 'x'.repeat(65536), '"' + '\\'.repeat(2048), '--- open\ncomment\n---\nconstant value is 1.']) tokenize(source);
// Tokenize real source files too, without treating lexical coloring as validation.
let sources = 0;
function walk(directory) {
  if (!existsSync(directory)) return;
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const file = join(directory, entry.name);
    if (entry.isDirectory()) walk(file);
    else if (entry.name.endsWith('.rt')) { tokenize(readFileSync(file, 'utf8')); sources++; }
  }
}
walk(resolve(root, '../../std'));
registry.dispose();
console.log(`Passed ${assertions} scope assertions, ${expressions} Oniguruma expressions, and ${sources} standard-library files.`);
