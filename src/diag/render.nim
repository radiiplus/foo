import std/strutils
import std/json
import std/algorithm
import std/tables
import ./engine
import ./code
import ./span
import ./palette

type
  Style* = object
    color*: bool
    file*: string
    contextLines*: int
    style*: string
    codes*: bool

proc title(code: Code): string =
  case code
  of Unexpected: "Unexpected token"
  of Unterminated: "Unterminated"
  of Invalid: "Invalid"
  of InvalidEscape: "Invalid escape sequence"
  of Digit: "Invalid digit"
  of Syntax: "Syntax error"
  of Missing: "Missing"
  of Extra: "Extra"
  of Duplicate: "Duplicate"
  of Hidden: "Hidden"
  of Clash: "Conflict"
  of Absent: "Not found"
  of Circular: "Circular dependency"
  of TypeMismatch: "Type mismatch"
  of NotCallable: "Not callable"
  of NotIndexable: "Not indexable"
  of NotIterable: "Not iterable"
  of FieldNotFound: "Field not found"
  of VariantNotFound: "Variant not found"
  of ScopeEscape: "Scope escape"
  of Undefined: "Undefined"
  of NotExported: "Not exported"
  of AlreadyImported: "Already imported"
  of NonExhaustive: "Non-exhaustive match"
  of UnreachableCase: "Unreachable case"
  of BackendError: "Backend error"
  of LinkError: "Link error"
  of CBinding: "C binding error"
  of NativePublic: "Native escape hatch in public API"
  of PkgConflict: "Dependency conflict"
  of PkgHashMismatch: "Hash mismatch"
  of PkgNotFound: "Package not found"
  of ErrorContext: "Error context"
  of UncaughtError: "Uncaught error"
  of TestFailed: "Test failed"

proc description(code: Code): string =
  case code
  of Unexpected: "I found something I wasn't expecting here"
  of Unterminated: "This never got closed properly"
  of TypeMismatch: "The types don't match up"
  of Undefined: "This hasn't been defined yet"
  else: title(code)

proc name(code: Code): string = "FOO" & align($ord(code), 4, '0')

proc paint(value, role: string; options: Style): string =
  if options.color: shade(role) & value & "\e[0m"
  else: value

proc expand(value: string; width = 4): string =
  for character in value:
    if character == '\t': result.add(' '.repeat(width - (result.len mod width)))
    else: result.add(character)

proc friendly(message: Message): string =
  let value = message.text
  if value.startsWith("expected "): return "Expected " & value[9 .. ^1]
  if value == "unterminated string": return "String is missing its closing \""
  if value == "unterminated character literal": return "Character is missing its closing '"
  if value.startsWith("undefined symbol '") and value.endsWith("'"):
    return value[18 ..< value.len - 1] & "' is not defined"
  if value.len > 0: return value[0].toUpperAscii & value[1 .. ^1]
  title(message.code)

proc marker(origin: string; column: int; location: Span): string =
  let offset = min(max(0, column - 1), origin.len)
  let requested = max(1, location.`end` - location.start)
  let available = max(1, origin.len - offset)
  let length = min(requested, available)
  let indentation = expand(origin[0 ..< offset]).len
  let underline = max(1, expand(origin[offset ..< min(origin.len, offset + length)]).len)
  ' '.repeat(indentation) & '^'.repeat(underline)

proc location(message: Message; options: Style): tuple[file: string, line, column: int] =
  result.file = if options.file.len > 0: options.file elif message.file.len > 0: message.file else: "<source>"
  result.line = max(1, message.span.line)
  result.column = max(1, message.span.col)

proc brief(message: Message; source: string; options: Style): string =
  let position = location(message, options)
  let lines = source.replace("\r\n", "\n").replace("\r", "\n").split('\n')
  var output = @[paint(position.file & ":" & $position.line & ":" & $position.column, "info", options), ""]
  if source.len > 0 and position.line - 1 < lines.len:
    let origin = lines[position.line - 1]
    output.add("  " & expand(origin))
    output.add("  " & paint(marker(origin, position.column, message.span), "error", options))
    output.add("")
  for part in friendly(message).split('\n'): output.add("  " & paint(part, "error", options))
  for related in message.related:
    output.add("")
    output.add("  " & paint("Related:", "info", options) & " " & related.text & " (" & (if related.file.len > 0: related.file else: position.file) & ":" & $related.span.line & ":" & $related.span.col & ")")
  var fix = ""
  for item in message.notes:
    if item.fix.len > 0: fix = item.fix; break
  if fix.len == 0: fix = message.suggestion
  if fix.len == 0 and message.fixes.len > 0: fix = message.fixes[0].title
  if fix.len > 0: output.add(""); output.add("  " & paint("Try:", "info", options) & " " & fix)
  if options.codes: output.add(""); output.add("  " & paint("Code:", "muted", options) & " " & name(message.code))
  output.join("\n")

proc verbose(message: Message; source: string; options: Style): string =
  let position = location(message, options)
  var output = @[paint("error[" & name(message.code) & "]", "error", options) & ": " & message.text,
    "  " & paint("-->", "info", options) & " " & position.file & ":" & $position.line & ":" & $position.column]
  let lines = source.replace("\r\n", "\n").replace("\r", "\n").split('\n')
  if source.len > 0 and position.line - 1 < lines.len:
    let origin = lines[position.line - 1]
    output.add("  |")
    output.add("  " & $position.line & " | " & expand(origin))
    output.add("    | " & paint(marker(origin, position.column, message.span), "error", options) & " " & description(message.code))
    output.add("  |")
  if message.context.len > 0: output.add("  = " & paint("context:", "muted", options) & " " & message.context)
  for item in message.notes:
    output.add("  = " & paint("note:", "muted", options) & " " & item.text)
    if item.fix.len > 0: output.add("  = " & paint("help:", "info", options) & " " & item.fix)
  for related in message.related:
    output.add("  = " & paint("related:", "info", options) & " " & related.text & " (" & (if related.file.len > 0: related.file else: position.file) & ":" & $max(1, related.span.line) & ":" & $max(1, related.span.col) & ")")
  if message.suggestion.len > 0: output.add("  = " & paint("help:", "info", options) & " " & message.suggestion)
  output.join("\n")

proc notes(left, right: Message): bool =
  if left.notes.len != right.notes.len: return false
  for index in 0 ..< left.notes.len:
    if left.notes[index].text != right.notes[index].text or
        left.notes[index].fix != right.notes[index].fix:
      return false
  true

proc fixes(left, right: Message): bool =
  if left.fixes.len != right.fixes.len: return false
  for index in 0 ..< left.fixes.len:
    if left.fixes[index].title != right.fixes[index].title or
        left.fixes[index].text != right.fixes[index].text:
      return false
  true

proc same(left, right: Message): bool =
  ## Related spans carry relationships that should remain individually visible.
  if left.related.len > 0 or right.related.len > 0: return false
  left.code == right.code and
    left.text == right.text and
    left.suggestion == right.suggestion and
    left.context == right.context and
    notes(left, right) and
    fixes(left, right)

proc locations(messages: seq[Message]; options: Style): string =
  var path = initOrderedTable[string, seq[int]]()
  for message in messages:
    let position = location(message, options)
    if not path.hasKey(position.file): path[position.file] = @[]
    if position.line notin path[position.file]: path[position.file].add(position.line)
  for file in path.keys:
    path[file].sort()

  if path.len == 1:
    for _, lines in path:
      let label = if lines.len == 1: "Affected line:" else: "Affected lines:"
      return paint(label, "info", options) & " " & lines.join(", ")

  var output = @[paint("Affected locations:", "info", options)]
  for file, lines in path:
    let label = if lines.len == 1: "line " else: "lines "
    output.add("  " & file & ": " & label & lines.join(", "))
  output.join("\n")

proc position(position: Position): JsonNode = %* {"line": position.line, "character": position.character}
proc range(value: Range): JsonNode = %* {"start": position(value.start), "end": position(value.`end`)}

proc diagnostic*(message: Message): JsonNode =
  let content = range(message.span, message.source)
  var related = newJArray()
  for item in message.related:
    if item.file.len > 0 or message.file.len > 0:
      related.add(%* {"location": {"uri": (if item.file.len > 0: item.file else: message.file), "range": range(range(item.span, item.source))}, "message": item.text})
  var fixes = newJArray()
  for item in message.fixes:
    fixes.add(%* {"title": item.title, "uri": item.file, "edit": {"range": range(range(item.span, item.source)), "newText": item.text}})
  %* {"range": range(content), "severity": 1, "source": "foo", "code": name(message.code),
    "message": friendly(message), "relatedInformation": related, "data": {"version": 1, "fixes": fixes}}

proc message(message: Message; source: string; options: Style): JsonNode =
  let position = location(message, options)
  var notes = newJArray()
  for item in message.notes: notes.add(%* {"text": item.text, "fix": item.fix, "line": item.span.line, "column": item.span.col})
  %* {"version": 1, "severity": "error", "diagnostic": diagnostic(message), "code": name(message.code),
    "kind": title(message.code).toLowerAscii.replace(" ", "-"), "message": friendly(message),
    "detail": message.text, "file": position.file, "line": position.line, "column": position.column,
    "span": {"start": message.span.start, "end": message.span.`end`}, "source": source,
    "suggestion": message.suggestion, "notes": notes}

proc render*(message: Message; source = ""; options = Style(color: true)): string =
  let input = if source.len > 0: source else: message.source
  if options.style == "json": return pretty(message(message, input, options))
  if options.style == "verbose": return verbose(message, input, options)
  brief(message, input, options)

proc render*(messages: seq[Message]; options = Style(color: true)): string =
  if options.style == "json":
    var diagnostics = newJArray()
    for message in messages: diagnostics.add(message(message, message.source, options))
    return pretty(%* {"format": "foo.diagnostics", "version": 1, "diagnostics": diagnostics})
  var groups: seq[seq[Message]]
  for message in messages:
    var matched = false
    for group in groups.mitems:
      if same(group[0], message):
        group.add(message)
        matched = true
        break
    if not matched: groups.add(@[message])

  var rendered: seq[string]
  for group in groups:
    var value = render(group[0], group[0].source, options)
    if group.len > 1: value.add("\n\n" & locations(group, options))
    rendered.add(value)
  rendered.join("\n\n")
