<p align="center">
  <img src="https://raw.githubusercontent.com/radiiplus/foo/main/editors/textmate/images/icon.png" alt="FOO logo" width="128" height="128">
</p>

<h1 align="center">foo.iv</h1>

<p align="center">FOO language support that makes sentence-like systems code feel at home in Visual Studio Code.</p>

### Read FOO as clearly as you write it.

FOO replaces dense punctuation with readable, sentence-like syntax. Your editor
should understand that syntax too, without replacing your favorite theme or
changing how the rest of your workspace looks.

**foo.iv brings FOO into focus.**

Open any `.iv` file for expressive syntax highlighting, distinct file icons,
smart brackets and indentation, comment shortcuts, and ready-made snippets.

---

## See FOO Clearly

![FOO source in VS Code with syntax highlighting](https://raw.githubusercontent.com/radiiplus/foo/main/editors/textmate/images/highlight.png)

The extension recognizes declarations, control flow, types, functions,
constants, strings, numbers, comments, properties, attributes, native blocks,
and invalid syntax. Its FOO-specific accents work alongside your selected VS
Code theme.

```iv
function greet(name text) {
  display "Hello, " plus name.
}

greet("world").
```

---

## Why foo.iv?

### Syntax That Follows the Language

FOO words are highlighted by purpose, so types, functions, control flow, and
operators remain easy to scan even when code reads like prose. Invalid syntax
stands apart before it gets lost in a larger file.

### Your Theme, With FOO Accents

foo.iv adds an Ultraviolet / Acid palette to FOO tokens while leaving your
chosen VS Code theme in control of the editor, interface, and other languages.

### Editing That Feels Native

Quotes, brackets, and braces close automatically. Indentation follows FOO
blocks, line and block comments use the right delimiters, and `.iv` files carry
recognizable icons in tabs and the Explorer.

### Snippets for Everyday Code

Start typing a prefix and select the FOO suggestion:

| Prefix | Inserts |
| --- | --- |
| `function` | Function declaration |
| `test` | Test block |
| `when` | Conditional block |
| `for each` | Collection loop |
| `constant` | Constant declaration |
| `native` | Native block |

Use `--` for line comments and `--- ... ---` for block comments.

---

## Quick Start

1. Open **Extensions** in Visual Studio Code.
2. Search for **foo.iv** and choose the extension published by **radiiplus**.
3. Select **Install**, then open any `.iv` file.

FOO appears as the active language in the status bar. To install a downloaded
package instead, choose **Install from VSIX** in the Extensions view and select
`foo.iv-2.1.0.vsix`.

---

## Mixed `.iv` Projects

If another extension also claims `.iv` files, open the language selector in the
status bar and choose **FOO**. Keep that choice for a workspace with a file
association:

```json
{
  "files.associations": {
    "*.iv": "foo"
  }
}
```

---

## Documentation

Learn the language in the [FOO documentation](https://github.com/radiiplus/foo/tree/main/docs),
begin with the [getting-started guide](https://github.com/radiiplus/foo/blob/main/docs/start.md),
or keep the [syntax reference](https://github.com/radiiplus/foo/blob/main/docs/syntax.md)
nearby while you work.

Found an editor issue? [Report it on GitHub](https://github.com/radiiplus/foo/issues).

foo.iv is available under the [MIT License](LICENSE).
