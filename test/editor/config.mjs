import assert from 'node:assert/strict';
import { readFileSync as read } from 'node:fs';
import { createRequire } from 'node:module';
import tm from 'vscode-textmate';
import onig from 'vscode-oniguruma';

const require = createRequire(import.meta.url);
const manifest = JSON.parse(read(new URL('../../editors/textmate/package.json', import.meta.url), 'utf8'));
const language = manifest.contributes.languages.find(item => item.id === 'foo-config');
assert.deepEqual(language.extensions, ['.ivc', '.cap']);
const lockLanguage = manifest.contributes.languages.find(item => item.id === 'foo-lock');
assert.deepEqual(lockLanguage.extensions, ['.ivl']);
assert.equal(lockLanguage.configuration, './lock-language.json');
const sourceLanguage = manifest.contributes.languages.find(item => item.id === 'foo');
const iconRoot = new URL('../../editors/textmate/', import.meta.url);
const assetRoot = new URL('../../assets/', import.meta.url);
const badgeColors = {
  'foo-config': { light: '#2E7D32', dark: '#98E66B' },
  'foo-lock': { light: '#A65300', dark: '#FFBE5C' },
};
for (const variant of ['light', 'dark']) {
  const icons = [sourceLanguage, language, lockLanguage].map(item => {
    const svg = read(new URL(item.icon[variant], iconRoot), 'utf8');
    assert.match(svg, /viewBox="0 0 16 16"/);
    return svg;
  });
  assert.equal(new Set(icons).size, 3, `${variant} file icons must be distinct`);
  const colors = [variant === 'light' ? '#7540A0' : '#C9A5F0',
    ...[language, lockLanguage].map(item => badgeColors[item.id][variant])];
  assert.equal(new Set(colors).size, 3, `${variant} badge colors must be distinct`);
  const mark = icons[0].match(/<path[^>]*d="([^"]+)"/)?.[1];
  assert(mark, `${variant} source icon needs a mark`);
  for (const svg of icons.slice(1))
    assert.equal(svg.match(/<path[^>]*d="([^"]+)"/)?.[1], mark,
      `${variant} file icons must share the source mark`);
  for (const [index, name] of [[1, 'config'], [2, 'lock']]) {
    const transform = name === 'config' ? 'translate(12.42 12.21) scale(.36)' :
      'translate(8.1 8.97) scale(.42 .36)';
    assert(icons[index].includes(`fill="${colors[index]}" fill-rule="evenodd" transform="${transform}"`),
      `${name} badge should match the source dot's footprint`);
    const assetName = `${name}${variant === 'light' ? '-light' : ''}.svg`;
    const asset = read(new URL(assetName, assetRoot), 'utf8');
    assert.equal(icons[index], asset.replace('width="96" height="96"',
      'width="16" height="16"'), `${assetName} and the editor icon differ`);
  }
}
for (const item of [language, lockLanguage]) {
  const light = read(new URL(item.icon.light, iconRoot), 'utf8');
  const dark = read(new URL(item.icon.dark, iconRoot), 'utf8');
  assert.equal(light.replace('#087F8C', '#60D5DF')
    .replace(badgeColors[item.id].light, badgeColors[item.id].dark),
    dark, `${item.id} light and dark geometry must match`);
}
const contribution = manifest.contributes.grammars.find(item => item.language === language.id);
assert.equal(contribution.scopeName, 'source.foo.config');
const path = new URL('../../editors/textmate/grammars/config.json', import.meta.url);
const raw = tm.parseRawGrammar(read(path, 'utf8'), path.pathname);
assert.equal(raw.scopeName, contribution.scopeName);
const lockContribution = manifest.contributes.grammars.find(item => item.language === lockLanguage.id);
const lockPath = new URL('../../editors/textmate/grammars/lock.json', import.meta.url);
const lockRaw = tm.parseRawGrammar(read(lockPath, 'utf8'), lockPath.pathname);
assert.equal(lockRaw.scopeName, lockContribution.scopeName);
await onig.loadWASM(read(require.resolve('vscode-oniguruma/release/onig.wasm')));
const rules = manifest.contributes.configurationDefaults['editor.tokenColorCustomizations'].textMateRules;
const registry = new tm.Registry({
  theme: { settings: [{ settings: { foreground: '#D4D4D4' } }, ...rules] },
  onigLib: Promise.resolve({
    createOnigScanner: patterns => new onig.OnigScanner(patterns),
    createOnigString: text => new onig.OnigString(text),
  }),
  loadGrammar: async scope => scope === raw.scopeName ? raw : scope === lockRaw.scopeName ? lockRaw : null,
});
const grammar = await registry.loadGrammar(raw.scopeName);
assert(grammar);
const checks = [
  ['version is 1', 'version', 'variable.other.property.foo.config', '#8BD3FF'],
  ['version is 1', 'is', 'keyword.operator.foo.config', '#FF79C6'],
  ['version is 1', '1', 'constant.numeric.foo.config', '#B6FF00'],
  ['capability "network"', 'capability', 'keyword.control.foo.config', '#F15BB5'],
  ['capability "network"', 'network', 'string.quoted.double.foo.config', '#00E5FF'],
  ['network { port is 8443 }', 'port', 'variable.other.property.foo.config', '#8BD3FF'],
  ['limit is 1GiB # memory size', '1GiB', 'constant.numeric.foo.config', '#B6FF00'],
  ['limit is 1GiB # memory size', 'memory', 'comment.line.foo.config', '#8A9099'],
  ['secure enable', 'enable', 'keyword.operator.foo.config', '#FF79C6'],
  ['default is true', 'true', 'constant.language.foo.config', '#D66BFF'],
  ['override port is 8080', 'override', 'keyword.control.foo.config', '#F15BB5'],
];
for (const [source, word, scope, color] of checks) {
  const start = source.indexOf(word);
  const { tokens } = grammar.tokenizeLine(source, tm.INITIAL);
  assert(tokens.some(token => token.startIndex <= start && token.endIndex >= start + word.length &&
    token.scopes.includes(scope)), `${word} should have ${scope}`);
  const binary = grammar.tokenizeLine2(source, tm.INITIAL).tokens;
  let index = 0;
  while (index + 2 < binary.length && binary[index + 2] <= start) index += 2;
  assert.equal(registry.getColorMap()[(binary[index + 1] >>> 15) & 0x1ff], color, `${word} color`);
}
const lockGrammar = await registry.loadGrammar(lockRaw.scopeName);
assert(lockGrammar);
const lockChecks = [
  ['{"packages": [{"name": "demo", "direct": true, "version": 1}]}', '"packages"', 'variable.other.property.foo.ivl', '#8BD3FF'],
  ['{"packages": [{"name": "demo", "direct": true, "version": 1}]}', 'demo', 'string.quoted.double.foo.ivl', '#00E5FF'],
  ['{"packages": [{"name": "demo", "direct": true, "version": 1}]}', 'true', 'constant.language.foo.ivl', '#D66BFF'],
  ['{"packages": [{"name": "demo", "direct": true, "version": 1}]}', '1', 'constant.numeric.foo.ivl', '#B6FF00'],
];
for (const [source, word, scope, color] of lockChecks) {
  const start = source.indexOf(word);
  const { tokens } = lockGrammar.tokenizeLine(source, tm.INITIAL);
  assert(tokens.some(token => token.startIndex <= start && token.endIndex >= start + word.length &&
    token.scopes.includes(scope)), `${word} should have ${scope}`);
  const binary = lockGrammar.tokenizeLine2(source, tm.INITIAL).tokens;
  let index = 0;
  while (index + 2 < binary.length && binary[index + 2] <= start) index += 2;
  assert.equal(registry.getColorMap()[(binary[index + 1] >>> 15) & 0x1ff], color, `${word} color`);
}
registry.dispose();
console.log(`Configuration syntax: ${checks.length + lockChecks.length} token and color checks passed.`);
