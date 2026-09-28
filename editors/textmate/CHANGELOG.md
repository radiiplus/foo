# Changelog

## 2.5.0 - 2026-09-28

- Remove highlighting and snippets for deprecated language spellings and
  compiler-internal native blocks.
- Use canonical parenthesized calls in documentation and completion examples.
- Align tokens, fixtures, and live language-server checks with FOO 0.5.0.

## 2.4.1 - 2026-09-28

- Report when the FOO language server has initialized successfully.
- Validate top-level `display`, `define`, `dynamic`, defaults, postfix `try`,
  `fallback`, and `stop`/`skip` through the live compiler-backed server.
- Use the compiler's complete analysis pipeline for editor diagnostics, hover,
  and navigation.

## 2.4.0 - 2026-09-28

- Align highlighting and snippets with the `failable`, postfix `try`, plural
  binding, named argument, closure, guard, type, collection, and native syntax
  shipped by FOO 0.4.0.
- Ship the live language-server client and project watcher with current command,
  configuration, diagnostic, hover, and definition behavior.
- Refresh the extension metadata and documentation for the current package and
  repository assets.

## 2.3.0 - 2026-09-26

- Highlight sentence-style function parameters, defaults, plural declarations,
  postfix failure handling, and intentional increase/decrease mutations.
- Update completions to emit current function syntax and add loops, matching,
  mutation, failure handling, explicit entry points, and native C/Zig blocks.
- Verify modern syntax through both TextMate scope tests and the live FOO
  language server before publishing diagnostics for invalid edits.

## 2.2.0 - 2026-09-26

- Start `foo lsp` for live diagnostics as `.iv` documents are opened and
  changed, with hover and go-to-definition support.
- Add commands to restart the language server and launch `foo watch` in a
  project terminal.
- Allow a custom compiler path while keeping syntax highlighting available
  when the compiler is not installed.

## 2.1.0 - 2026-09-25

- Replace the former mark with a clear numeral 4 across the Marketplace icon,
  file icons, and package screenshot.
- Focus the Marketplace README on installation and everyday usage.
- Publish the Marketplace package as `foo.iv` with the `radiiplus.foo-iv`
  extension identity.
- Replace the retired compiler fixture with complete library modules and usage
  tests, preserving a 200+ line corpus with token snapshots.
- Highlight the current `define`, `dynamic`, `stop`, `skip`, `fallback`,
  `multiply`, `subtract`, and `divide` vocabulary.
- Update snippets and fixtures for top-level statements, implicit completion,
  concise type annotations, and camel-case standard-library calls.
- Document postfix `try` and direct inclusive comparison phrases used by the
  current compiler.

## 2.0.0 — 2026-09-14

- Rename the language to FOO, the language ID to `foo`, the scope to `source.foo`,
  and source files to `.iv`; the extension identity is now `radiiplus.foo-iv`.
- Update the grammar, fixtures, icon, tests, and syntax palette selectors.
- Preserve the user's selected theme and other languages' syntax colors.

## 1.1.1 — 2026-09-14

- Replace the full Ultraviolet theme with Tratio-only syntax color defaults
  that apply alongside the user's selected theme.
- Remove interface, terminal, diagnostic, and other-language color overrides.
  Ordinary identifiers inherit their theme's colors.
- Verify the palette on stock dark and light themes and preserve theme selection.

## 1.1.0 — 2026-09-14

- Add the optional Tratio Ultraviolet / Acid theme, including editor diagnostics,
  Debug Console, terminal ANSI, and standard log severity colors.
- Highlight constant declaration names and adjacent property access separately;
  preserve neutral unresolved references and existing language syntax.
- Use brighter slate comments and reserve red for invalid syntax and failures.
- Add resolved color assertions and verify the actual palette in VS Code.

## 1.0.1 — 2026-09-13

- Color `of` and `to` as word operators and split `of type` into separate
  operator and type annotation scopes, replacing neutral connective highlighting.
- Verify three visible color groups in stock Dark Modern and Light Modern themes;
  update scope snapshots and the real editor screenshot.

## 1.0.0 — 2026-09-13

- Distinguish neutral type connectives, primitive types, type modifiers, and
  named types using standard TextMate scope families. No theme is bundled.
- Add nine real-source fixture families with full per-line scope snapshots,
  including a complete 200+ line code example.
- Add push and pull-request CI for tokenization, regression detection, and
  isolated VS Code editor behavior.
- Add light/dark SVG file icons, language-specific bracket colorization,
  word selection, and block indentation rules.
- Verify detection, both comment toggles, auto-closing, surrounding, indentation,
  bracket matching, token inspection, rendered type colors, and explorer/tab icons.

## 0.1.0 — 2026-09-13

- Initial Tratio `.rt` lexical grammar, MIT license, and focused scope tests.
- Documentation comment scopes for the editor-only `--!` and `---!` convention.
