# Diagnostics
Version: 1.

The default diagnostic shows the location, relevant source, problem and a useful fix. It omits internal codes and stage names.

```text
main.iv:8:8

  give totl.
       ^^^^

  'totl' is not defined

  Did you mean 'total'?
```

A known missing token gets a concrete correction:

```text
main.iv:4:13

  give value
            ^

  Missing '.'

  Try: give value.
```

Type errors show separate expected and found types using their canonical FOO spellings. Suggestions must refer to visible names or valid edits; uncertain guesses are labeled as suggestions, not automatic corrections.

## Presentation
Locations use one-based lines and Unicode scalar columns. CRLF counts as one line ending. Tabs count as one scalar in coordinates but expand to tab stops of four cells in displayed excerpts; caret placement follows the displayed cells. Machine spans use zero-based UTF-8 byte offsets with an exclusive end.

Show at most five primary diagnostics by default, followed by a compact total and a hint when more exist. Consequential errors caused by the same missing declaration or malformed construct should not obscure independent errors. Order diagnostics by normalized file path, start offset, severity and code.

`foo check --verbose` includes codes, related locations and technical context. `foo check --json` emits only the machine envelope, with no ANSI sequences or human progress output. Color is optional and never the only indicator of severity. Missing source text still permits a location and explanation.

## Machine format
The envelope is UTF-8 JSON with `format: "foo.diagnostics"`, `version: 1` and a `diagnostics` array. Each diagnostic has:

| Field | Value |
| --- | --- |
| `severity` | `error`, `warning` or `info` |
| `code` | Stable language-facing diagnostic identifier |
| `message` | Plain explanation |
| `file` | Project-relative slash-separated path, or null |
| `span` | `{ "start": integer, "end": integer }` byte offsets, or null |
| `location` | `{ "line": integer, "column": integer }`, or null |
| `notes` | Array of plain strings |
| `related` | Array of objects with message, file, span and location |
| `fixes` | Array of objects with message, applicability and edits |

Applicability is `certain` or `suggested`. Each edit has a file, span and replacement string; edits within one fix cannot overlap. All fields listed above are required, using null or empty arrays where needed. Unknown fields, severities and versions are rejected by strict v1 consumers.

Diagnostics about generated code map to FOO source wherever a source span exists. Public errors describe the violated FOO contract; a substrate's raw diagnostic may appear only as additional verbose context.
