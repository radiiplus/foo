import std/[json, math, os, strutils, tables]

type
  Location* = object
    file*: string
    line*: int
    column*: int
  Document* = object
    values*: JsonNode
    files*: seq[string]
    origins*: Table[string, Location]
  TokenKind = enum word, quoted, punctuation, terminal
  Token = object
    kind: TokenKind
    text: string
    location: Location
  Context = ref object
    root: string
    active: seq[string]
    document: Document
    layers: Table[string, int]
    nextLayer: int
  Parser = object
    tokens: seq[Token]
    position: int
    context: Context
    file: string
    layer: int

proc fail(location: Location; message: string) {.noreturn.} =
  raise newException(ValueError, location.file & ":" & $location.line &
    ":" & $location.column & ": " & message)

proc tokenize(file, source: string): seq[Token] =
  var index = 0
  var line = 1
  var column = 1
  proc advance() =
    if source[index] == '\n':
      inc line
      column = 1
    else: inc column
    inc index
  while index < source.len:
    let character = source[index]
    if character in {' ', '\t', '\r', '\n'}:
      advance()
      continue
    if character == '#' or
        (index + 1 < source.len and source[index .. index + 1] in ["//", "--"]):
      while index < source.len and source[index] != '\n': advance()
      continue
    let location = Location(file: file, line: line, column: column)
    if character == '"':
      let start = index
      advance()
      var closed = false
      while index < source.len:
        if source[index] == '\\':
          advance()
          if index >= source.len: fail(location, "unterminated string")
          advance()
        elif source[index] == '"':
          advance()
          closed = true
          break
        else: advance()
      if not closed: fail(location, "unterminated string")
      try:
        let decoded = parseJson(source[start ..< index])
        result.add(Token(kind: quoted, text: decoded.getStr(), location: location))
      except CatchableError:
        fail(location, "invalid string escape")
    elif character in {'{', '}', '[', ']', ','}:
      result.add(Token(kind: punctuation, text: $character, location: location))
      advance()
    else:
      let start = index
      while index < source.len and source[index] notin
          {' ', '\t', '\r', '\n', '{', '}', '[', ']', ',', '#'}:
        if index + 1 < source.len and source[index .. index + 1] in ["//", "--"]:
          break
        advance()
      if index == start: fail(location, "unexpected character")
      result.add(Token(kind: word, text: source[start ..< index], location: location))
  result.add(Token(kind: terminal, location: Location(file: file,
    line: line, column: column)))

proc current(parser: Parser): Token = parser.tokens[parser.position]

proc take(parser: var Parser): Token =
  result = parser.current()
  if result.kind != terminal: inc parser.position

proc require(parser: var Parser; value: string) =
  if parser.current().text != value:
    fail(parser.current().location, "expected '" & value & "'")
  discard parser.take()

proc name(token: Token): string =
  if token.kind != word or token.text.len == 0 or
      token.text[0] notin {'a'..'z', 'A'..'Z'}:
    fail(token.location, "expected a declaration name")
  for character in token.text:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      fail(token.location, "invalid declaration name '" & token.text & "'")
  token.text

proc quantity(token: Token): JsonNode =
  let input = token.text
  var digits = 0
  if input.startsWith("-"): inc digits
  while digits < input.len and input[digits] in {'0'..'9'}: inc digits
  if digits == 0 or (digits == 1 and input[0] == '-'):
    fail(token.location, "expected a number")
  let suffix = input[digits .. ^1]
  let factors = {
    "KB": 1000'i64, "MB": 1000000'i64, "GB": 1000000000'i64,
    "TB": 1000000000000'i64, "KiB": 1024'i64,
    "MiB": 1048576'i64, "GiB": 1073741824'i64,
    "TiB": 1099511627776'i64, "ms": 1000000'i64,
    "s": 1000000000'i64, "min": 60000000000'i64,
    "h": 3600000000000'i64}.toTable()
  if suffix.len > 0 and factors.hasKey(suffix):
    var value: BiggestInt
    try: value = parseBiggestInt(input[0 ..< digits])
    except ValueError: fail(token.location, "invalid or overflowing number '" & input & "'")
    let factor = factors[suffix]
    if value > high(int64) div factor or value < low(int64) div factor:
      fail(token.location, "quantity overflows a signed 64-bit value")
    return %((value * factor).int64)
  if suffix.len == 0:
    try: return %(parseBiggestInt(input).int64)
    except ValueError: fail(token.location, "invalid or overflowing number '" & input & "'")
  if input.contains('.') or input.contains('e') or input.contains('E'):
    var value: float
    try: value = parseFloat(input)
    except ValueError: fail(token.location, "invalid or overflowing number '" & input & "'")
    if classify(value) in {fcInf, fcNegInf, fcNan}:
      fail(token.location, "nonfinite number")
    return %value
  fail(token.location, "unknown unit or malformed number '" & input & "'")

proc key(prefix, field: string): string =
  if prefix.len == 0: field else: prefix & "." & field

proc assign(parser: var Parser; target: JsonNode; prefix, field: string;
    value: JsonNode; location: Location; replace = false) =
  let path = key(prefix, field)
  if target.hasKey(field):
    let previous = parser.context.document.origins.getOrDefault(path)
    if not replace and previous.file == location.file and
        parser.context.layers.getOrDefault(path) == parser.layer:
      fail(location, "duplicate '" & path & "' (first declared at " &
        previous.file & ":" & $previous.line & ":" & $previous.column &
        ")")
  elif replace:
    fail(location, "override needs an earlier declaration of '" & path & "'")
  target[field] = value
  parser.context.document.origins[path] = location
  parser.context.layers[path] = parser.layer

proc declarations(parser: var Parser; target: JsonNode; prefix: string;
    depth: int; closing: bool)
proc ingest(context: Context; path: string; target: JsonNode;
    prefix: string; depth: int)

proc value(parser: var Parser; prefix: string; depth: int): JsonNode =
  if depth > 32: fail(parser.current().location, "configuration nesting exceeds 32 levels")
  let token = parser.take()
  case token.kind
  of quoted: result = %token.text
  of word:
    case token.text
    of "true": result = %true
    of "false": result = %false
    of "null": result = newJNull()
    else:
      if token.text[0] in {'0'..'9', '-'}: result = quantity(token)
      else: fail(token.location, "quote string values or use 'using'")
  of punctuation:
    if token.text == "[":
      result = newJArray()
      if parser.current().text != "]":
        while true:
          result.add(parser.value(prefix, depth + 1))
          if parser.current().text != ",": break
          discard parser.take()
      parser.require("]")
    elif token.text == "{":
      result = newJObject()
      parser.declarations(result, prefix, depth + 1, true)
    else: fail(token.location, "expected a value")
  of terminal: fail(token.location, "expected a value")

proc section(parser: var Parser; target: JsonNode; prefix, field: string;
    location: Location; depth: int): JsonNode =
  if depth > 32: fail(location, "configuration nesting exceeds 32 levels")
  let path = key(prefix, field)
  if target.hasKey(field):
    if target[field].kind != JObject:
      fail(location, "section conflicts with scalar '" & path & "'")
    return target[field]
  result = newJObject()
  target[field] = result
  parser.context.document.origins[path] = location

proc declarations(parser: var Parser; target: JsonNode; prefix: string;
    depth: int; closing: bool) =
  let outerLayer = parser.layer
  inc parser.context.nextLayer
  parser.layer = parser.context.nextLayer
  defer: parser.layer = outerLayer
  while true:
    let token = parser.current()
    if token.kind == terminal:
      if closing: fail(token.location, "unclosed section")
      return
    if token.text == "}":
      if not closing: fail(token.location, "unexpected closing brace")
      discard parser.take()
      return
    if token.text == "import":
      discard parser.take()
      let path = parser.take()
      if path.kind != quoted or not path.text.endsWith(".ivc"):
        fail(path.location, "import needs a quoted .ivc path")
      let absolute = absolutePath(path.text, parentDir(parser.file))
      parser.context.ingest(absolute, target, prefix, depth)
      continue
    if token.text == "capability" and prefix.len == 0:
      discard parser.take()
      let selected = parser.take()
      if selected.kind notin {word, quoted}:
        fail(selected.location, "capability needs a name")
      discard name(Token(kind: word, text: selected.text,
        location: selected.location))
      if not target.hasKey("capabilities"):
        target["capabilities"] = newJArray()
      for item in target["capabilities"]:
        if item.getStr() == selected.text:
          fail(selected.location, "duplicate capability '" & selected.text & "'")
      target["capabilities"].add(%selected.text)
      continue
    let replace = token.text == "override"
    if replace: discard parser.take()
    let identifier = parser.take()
    let field = if identifier.kind == quoted and identifier.text.len > 0:
        identifier.text else: name(identifier)
    if prefix.len == 0 and field == "format":
      fail(identifier.location, "format is assigned by the configuration engine")
    var named = ""
    if parser.current().kind == quoted:
      named = parser.take().text
      discard name(Token(kind: word, text: named,
        location: identifier.location))
    let operation = parser.take()
    if operation.text == "{":
      if replace: fail(identifier.location, "override applies to values, not sections")
      let parent = parser.section(target, prefix, field,
        identifier.location, depth + 1)
      if named.len > 0:
        let child = parser.section(parent, key(prefix, field), named,
          identifier.location, depth + 1)
        parser.declarations(child, key(key(prefix, field), named), depth + 1, true)
      else:
        parser.declarations(parent, key(prefix, field), depth + 1, true)
    else:
      if named.len > 0: fail(operation.location, "named sections need '{'")
      var parsed: JsonNode
      case operation.text
      of "is": parsed = parser.value(key(prefix, field), depth + 1)
      of "enable": parsed = %true
      of "disable": parsed = %false
      of "using":
        let selected = parser.take()
        if selected.kind notin {word, quoted}:
          fail(selected.location, "using needs an implementation name")
        parsed = %selected.text
      else: fail(operation.location, "expected is, enable, disable, using, or '{'")
      parser.assign(target, prefix, field, parsed, identifier.location, replace)

proc ingest(context: Context; path: string; target: JsonNode;
    prefix: string; depth: int) =
  let absolute = absolutePath(path)
  let root = context.root.toLowerAscii()
  let normalized = absolute.toLowerAscii()
  if normalized != root and not normalized.startsWith(root & DirSep):
    raise newException(ValueError, "Configuration import escapes root: " & path)
  if absolute in context.active:
    raise newException(ValueError, "Configuration import cycle: " &
      (context.active & @[absolute]).join(" -> "))
  if context.document.files.len >= 64:
    raise newException(ValueError, "Configuration imports exceed 64 files")
  if not fileExists(absolute):
    raise newException(IOError, "Configuration file not found: " & absolute)
  if getFileSize(absolute) > 1024 * 1024:
    raise newException(ValueError, "Configuration file exceeds 1 MiB: " & absolute)
  context.active.add(absolute)
  context.document.files.add(absolute)
  var parser = Parser(tokens: tokenize(absolute, readFile(absolute)),
    context: context, file: absolute)
  parser.declarations(target, prefix, depth, false)
  context.active.setLen(context.active.len - 1)

proc load*(path: string): Document =
  let absolute = absolutePath(path)
  let context = Context(root: parentDir(absolute),
    document: Document(values: newJObject(),
      origins: initTable[string, Location]()),
    layers: initTable[string, int]())
  context.ingest(absolute, context.document.values, "", 0)
  context.document.values["format"] = %1
  context.document

proc loadText*(content, path: string): Document =
  let absolute = absolutePath(path)
  let context = Context(root: parentDir(absolute),
    document: Document(values: newJObject(), files: @[absolute],
      origins: initTable[string, Location]()),
    layers: initTable[string, int]())
  var parser = Parser(tokens: tokenize(absolute, content),
    context: context, file: absolute)
  parser.declarations(context.document.values, "", 0, false)
  context.document.values["format"] = %1
  context.document

proc label(name: string): string =
  if name.len == 0 or name[0] notin {'a'..'z', 'A'..'Z'}:
    return $(%name)
  for character in name:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      return $(%name)
  name

proc scalar(value: JsonNode): string

proc entries(value: JsonNode; depth: int): string =
  let indent = repeat("  ", depth)
  for field, child in value:
    if child.kind == JObject:
      if child.len == 0:
        result.add(indent & label(field) & " {}\n")
      else:
        result.add(indent & label(field) & " {\n")
        result.add(entries(child, depth + 1))
        result.add(indent & "}\n")
    else:
      result.add(indent & label(field) & " is " & scalar(child) & "\n")

proc scalar(value: JsonNode): string =
  case value.kind
  of JArray:
    var parts: seq[string]
    for item in value: parts.add(scalar(item))
    "[" & parts.join(", ") & "]"
  of JObject:
    if value.len == 0: "{}"
    else: "{\n" & entries(value, 1) & "}"
  else: $value

proc renderValue*(value: JsonNode): string = scalar(value)

proc render*(values: JsonNode; capability = ""): string =
  if values.kind != JObject:
    raise newException(ValueError, "Configuration root must be an object")
  result = ""
  if values.hasKey("capabilities"):
    for selected in values["capabilities"]:
      result.add("capability " & $selected & "\n")
  elif capability.len > 0:
    result.add("capability " & $(%capability) & "\n")
  let content = newJObject()
  for key, value in values:
    if key notin ["format", "capabilities"]: content[key] = value
  result.add(entries(content, 0))
