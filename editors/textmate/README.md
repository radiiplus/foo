<p align="center">
  <img src="images/icon.png" alt="FOO 4 logo" width="128" height="128">
</p>

# FOO for VS Code

FOO language support for Visual Studio Code. Open any `.iv` file to get syntax highlighting, file icons, bracket handling, comment shortcuts, indentation, and ready-made snippets.

![FOO source in VS Code with the 4 file icon and syntax highlighting](images/highlight.png)

## Install

Open **Extensions** in Visual Studio Code, search for **FOO**, select the extension published by **radiiplus**, and choose **Install**.

To install a downloaded package instead, open the Extensions view, choose **Install from VSIX**, and select `foo-2.0.0.vsix`.

## Use FOO Files

Files ending in `.iv` open in FOO language mode automatically. The active language appears as **FOO** in the status bar.

```iv
function greet(name of type text) of type nothing {
  display "Hello, " plus name.
  give nothing.
}

start() {
  greet("world").
  give nothing.
}
```

The extension highlights declarations, control flow, types, functions, constants, strings, numbers, comments, properties, attributes, native blocks, and invalid syntax. Its FOO-specific colors work alongside the selected VS Code theme.

## Snippets

Start typing one of these names and select the FOO suggestion:

| Prefix | Inserts |
| --- | --- |
| `function` | Function declaration |
| `test` | Test block |
| `when` | Conditional block |
| `for each` | Collection loop |
| `constant` | Constant declaration |
| `native` | Native block |

Use `--` for line comments and `--- ... ---` for block comments. Quotes, brackets, and braces close automatically, and indentation follows FOO blocks.

## Mixed `.iv` Projects

If another extension also claims `.iv` files, open the language selector in the status bar and choose **FOO**. You can keep that choice for a workspace with a file association:

```json
{
  "files.associations": {
    "*.iv": "foo"
  }
}
```

## Documentation And Support

- [Get started with FOO](../../docs/start.md)
- [Language guide](../../docs/language.md)
- [Syntax reference](../../docs/syntax.md)
- [Report an issue](https://github.com/radiiplus/foo/issues)

## License

FOO for VS Code is available under the [MIT License](LICENSE).
