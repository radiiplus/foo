# FOO for VS Code

FOO declarations live directly at file level. The grammar highlights functions,
types, imports, and `where` clauses without a `module` wrapper. Legacy spellings
remain highlighted for migration; `foo fmt` writes canonical syntax.

Lexical highlighting and Ultraviolet / Acid syntax accents for FOO `.iv` files, with your existing VS Code theme.
Language ID: `foo`. TextMate scope: `source.foo`.

![FOO in VS Code, showing distinct type colors and file icons](images/highlight.png)

This is an actual Extension Development Host screenshot using **Dark Modern**.
Linking words are pink, type words are yellow, types are acid green, functions
are orange, and strings are cyan. Comments use the brighter slate `#8A9099`.
The palette applies to FOO tokens across themes. Backgrounds, interface colors,
terminal colors, and ordinary identifier colors come from your selected theme.

## Install

In your normal VS Code window, run **Extensions: Install from VSIX**, select
`foo-2.0.0.vsix`, and run **Developer: Reload Window**. `.iv` files should
then open as FOO, with a file icon in the explorer and tab bar. An icon
theme that supplies its own `.iv` icon can override the language fallback.

No theme selection is needed. The extension contributes FOO-scoped token color
defaults and does not install a theme or write settings. Your explicit token color
customizations retain their normal VS Code precedence over extension defaults.

To build the VSIX from this folder:

```sh
npm ci
npx --yes --omit=optional --package=@vscode/vsce@3.9.2 vsce package --no-dependencies --baseContentUrl=https://github.com/radiiplus/foo/blob/main/editors/textmate
code --install-extension foo-2.0.0.vsix
```

For development, from the compiler repository root:

```sh
code --extensionDevelopmentPath="./editors/textmate" ./test/editor/cases/pointers.iv
```

Use **Developer: Inspect Editor Tokens and Scopes** to inspect the grammar.
Installing in an isolated test profile does not install in your normal profile.
In mixed projects with other `.iv` formats, use **Change Language Mode** or a
workspace association restricted to FOO source directories. The extension
does not rewrite user settings. See the [extension collision note](../../docs/editors/iv.md).

## Language and scopes

The bundled pure-JSON grammar is [grammars/foo.tmLanguage.json](grammars/foo.tmLanguage.json).
It follows FOO's lexer and [current specification](../../specs/grammar.md),
including `constant`, `mutable`, `function`, `give`, word operators, generics,
`derives`, `packed record`, C unions, attributes, and native escape blocks.

| Role | Scope family | Examples |
| --- | --- | --- |
| Linking words | `keyword.other.operator.of.foo`, `keyword.other.operator.to.foo` | `of`, `to` |
| Type annotation word | `storage.type.annotation.foo` | `type` in `of type` |
| Primitive types | `support.type.primitive.foo` | `byte`, `text`, `integer`, `decimal` |
| Type modifiers | `storage.modifier.type.foo` | `pointer`, `reference`, `optional`, `fallible` |
| Type constructors | `storage.type.foo` | `record`, `choice`, `vector`, `sequence` |
| Named types | `entity.name.type.foo` | `Deque`, `Box`, `T` |
| Constant declarations | `variable.other.constant.foo` | `limit` in `constant limit is 42.` |
| Property access | `variable.other.property.foo` | `length` in `data.length` |

Constant declarations are violet; unresolved references retain your theme's identifier color.
Properties after an adjacent dot are light blue; calls remain orange. These
are lexical approximations. The theme includes semantic token mappings for a
future provider, but this package does not resolve bindings or identify built-ins.
Words such as `define`, `from`, `with`, and `into` remain ordinary identifiers
because the current compiler does not reserve them.

The token rules in [package.json](package.json) use `source.foo` selectors;
semantic color defaults use `:foo` selectors. Other languages, VS Code's
diagnostics, Debug Console, and terminal palette receive no color overrides.
The compiler's own build and diagnostic output uses matching role colors, with
24-bit terminal colors where supported and ANSI fallback elsewhere. Labels and
markers receive emphasis while message bodies remain neutral; JSON stays plain.

Comments use `--` and non-nesting `--- ... ---`. Text is single-line quoted
text; use `plus newline plus` to construct multiple lines. Supported text
escapes are `\n`, `\t`, `\r`, `\\`, `\"`, and `\0`; characters use single
quotes with `\'` instead of `\"`. Numbers are decimal integers or decimal-point
floats with underscores. A trailing dot terminates a statement.

Raw strings, multiline strings, hex/octal/binary numbers, and exponent notation
are not implemented by the current lexer and are not colored as supported
compound literals. The template's `let`, `fn`, and `return` remain identifiers.
Unterminated strings and invalid escapes receive `invalid.illegal.foo`.

Documentation comments use the editor-only convention `--!` and
`---! ... ---`, with separate documentation scopes. The compiler currently
discards these as ordinary comments; documentation extraction has not been added.

Generic declaration brackets, `vector[...]`, and capitalized generic type uses
are approximated lexically. Type resolution, precise generic/index ambiguity,
and diagnostic reporting belong to the compiler/LSP. The native Zig body rules
are deliberately small. No theme, LSP, activation script, or custom settings are
bundled. Defaults provide FOO token colors and enable bracket-pair colorization.

## Tests and CI

Run these from the compiler repository root; test dependencies are managed by
the root lockfile.

```sh
npm ci
npm run test:editor
npm run test:host
```

The [fixture corpus](../../test/editor/README.md) has nine construct families and full-line
scope assertions, including complete library modules and their usage tests.
There are 233 focused assertions, all 84 compiler keyword fixture lines, and
snapshots for over 400 lines. Every regex is compiled with Oniguruma.
There are also 34 assertions of resolved theme colors, including error overrides,
constant declarations, property access, and neutral unresolved references.
Normal tests only compare snapshots; deliberate regeneration uses
`node test/editor/snapshots.mjs --update`, followed by review of the diff.

The [GitHub Actions workflow](../../.github/workflows/grammar.yml) runs on every
push and pull request. It checks scopes, proves a corrupted assertion fails,
and runs the editor tests under Xvfb. Hosted CI runs when the commit is pushed;
local test results are not presented as a hosted CI run.

The editor harness downloads VS Code 1.96.4 into its test cache, or uses the
executable specified by the test-only `FOO_EDITOR` environment variable.
It creates fresh user-data and extension directories every time. It checks
language detection, comment toggles, bracket matching, auto-close/surround
pairs, indentation, word selection, token inspection, rendered type colors,
and SVG icons in both explorer and tabs. Screenshots and JSON evidence are
written to `.artifacts/editor/evidence`. The default is Dark Modern; `FOO_THEME` can select another theme
for verification; it is not an extension setting.

Local validation used a portable copy of VS Code 1.132.0. This allowed the
real editor gate to run despite the installed editor's stuck Windows updater.
The README screenshot comes from that isolated editor, not a mockup.

## Release pin

The FOO package is version 2.0.0, with extension identity `foo.foo`.
It replaces the former `tratio.tratio` extension. Remove that old local extension
after installing FOO to retire its `.rt` association and syntax color defaults.

The original annotated Git tag `v1.0.0` remains unchanged and records the
former Tratio `.rt` grammar at `editors/textmate/grammars/tratio.tmLanguage.json`.
It does not identify the renamed FOO grammar. Resolve that historical commit with `git rev-parse v1.0.0^{commit}`
when inspecting the original release. Never move or recreate this release
tag; later grammar changes require a new version. Remote publication and tag
protection remain repository-maintainer actions; no remote was created or pushed.

The existing repository hosts the grammar and declarative extension together.
`publisher: foo` is a local package identity, not a claim that a Marketplace
publisher has been registered. A separate remote grammar repository can later
preserve this release tree and its provenance.

## License and references

The grammar package, icons, fixtures, and screenshot are [MIT licensed](LICENSE).
See [CHANGELOG.md](CHANGELOG.md) for release changes.

Implementation references: [VS Code language contributions](https://code.visualstudio.com/api/references/contribution-points#contributes.languages),
[color themes](https://code.visualstudio.com/api/extension-guides/color-theme),
[language configuration](https://code.visualstudio.com/api/language-extensions/language-configuration-guide),
and [TextMate scope conventions](https://macromates.com/manual/en/language_grammars#naming_conventions).
