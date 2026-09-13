# Tratio editor naming

Status: frozen for Batch 0.1, 2026-09-13.

These decisions use the project's existing Tratio identity and `.rt` source
files, as requested. They govern subsequent editor and GitHub integration work.

| Surface | Frozen value |
| --- | --- |
| Language display name | `Tratio` |
| VS Code language identifier | `tratio` |
| Root TextMate scope | `source.tratio` |
| Source extension | `.rt` |
| Grammar filename | `tratio.tmLanguage.json` |
| Grammar location within the extension | `grammars/tratio.tmLanguage.json` |
| Compiler command | `tratio` |

Batch 1.1 places the grammar under `grammars/`, following that batch's requested
package layout. This replaces the earlier proposed `syntaxes/` directory;
the frozen filename, language ID, scope, and source extension are unchanged.
The local package is [editors/textmate](../../editors/textmate/README.md).

Keep `.rt`. Existing projects, imports, examples, and build inputs must retain
their names. The Arc identifiers in the batch template are superseded by this
table; `.arc`, `arc`, and `source.arc` are not Tratio aliases.

The future extension must use `tratio` for both `contributes.languages[].id`
and `contributes.grammars[].language`, `.rt` in the language's `extensions`, and
`source.tratio` for both the grammar contribution's `scopeName` and the grammar
file's root `scopeName`. These are distinct manifest fields, as described in
the [VS Code grammar contribution guide](https://code.visualstudio.com/api/language-extensions/syntax-highlight-guide#contributing-a-basic-grammar).
The language ID is not the publisher-qualified Marketplace extension ID;
publishing identity remains outside this batch.

## Syntax authority

Editor detection and highlighting must follow [the current grammar](../../spec/grammar.md)
and compiler, including these characteristic forms:

```tratio
module sample {
  type Box[T] is record {
    value of type T.
  } derives Eq, Hash.

  function identity[T](value of type T) {
    give value.
  }
}
```

Other useful signals are `constant ... is`, `mutable ... is`, `use c "header.h".`,
`public use "crypto" function`, `match` with `case` and `when`, `on leave`,
`optional`, and `fallible`. Derivation uses `derives`; do not make detection
depend on `#[derive(...)]`. Likewise, the template's `let`, `fn`, `defer`,
`?T`, `!T`, and `std::` are not the canonical spellings to teach users.
Generic syntax, word operators, sentence-ending dots, and the `newline` value
remain part of the language's existing style.

## Collision mitigation

The [collision audit](collision-audit.md) confirms other `.rt` consumers:
React Templates, miniRT scene descriptions, and rainbow tables. RealText
subtitles are also documented users of this suffix. Sharing a suffix does
not justify migrating Tratio projects.

1. The future VS Code extension declares `.rt`, but must preserve the user's
   explicit language selection and workspace associations. In a mixed project,
   recommend associations restricted to its Tratio source directories, for
   example `"files.associations": { "src/**/*.rt": "tratio" }`, once the
   Tratio extension is installed. Provide the Change Language Mode fallback.
   Do not silently rewrite users' global settings. VS Code documents both
   [language selection and file associations](https://code.visualstudio.com/docs/languages/overview#_changing-the-language-for-the-selected-file).
2. For future GitHub Linguist integration, use conservative content detection
   and negative fixtures for competing formats. The combined candidate in the
   audit is a draft, with abstention on ambiguous input. A TextMate grammar
   tokenizes a selected language; it does not itself implement this repository
   classification policy.
3. Before submitting Linguist support, complete the wider search audit, add
   representative fixtures, and validate the rule in Linguist's own regex
   engines and test suite. Repository-local `linguist-language=Tratio` overrides
   are a later mitigation, after Linguist recognizes that language name.
   Follow the [Linguist contribution requirements](https://github.com/github-linguist/linguist/blob/main/CONTRIBUTING.md).

This batch records decisions and evidence only. It does not install an editor
extension, register a grammar, or change compiler syntax.
