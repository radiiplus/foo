import std/options
import std/strutils
import ./kind
import ./token
import ../diag/engine
import ../diag/code
import ../diag/span

type
  Lexer* = ref object
    src: string
    pos, line, col: int
    diag: Engine
    start, startLine, startCol: int

proc newLexer*(src: string; diag: Engine): Lexer =
  Lexer(src: src, diag: diag, line: 1, col: 1, startLine: 1, startCol: 1)

proc mark(lexer: Lexer) =
  lexer.start = lexer.pos
  lexer.startLine = lexer.line
  lexer.startCol = lexer.col

proc span(lexer: Lexer): Span =
  Span(start: lexer.start, `end`: lexer.pos, line: lexer.startLine, col: lexer.startCol)

proc read(lexer: Lexer): char =
  if lexer.pos >= lexer.src.len: return '\0'
  result = lexer.src[lexer.pos]
  inc lexer.pos
  if result == '\n':
    inc lexer.line
    lexer.col = 1
  else:
    inc lexer.col

proc letter(ch: char): bool = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')
proc digit(ch: char): bool = ch >= '0' and ch <= '9'
proc alnum(ch: char): bool = letter(ch) or digit(ch)

proc make(lexer: Lexer; kind: Kind; text: string): Token =
  Token(kind: kind, span: lexer.span(), text: text)

proc skip(lexer: Lexer) =
  while lexer.pos < lexer.src.len and lexer.src[lexer.pos] in {' ', '\t', '\r'}: discard lexer.read()

proc scanline(lexer: Lexer) =
  while lexer.pos < lexer.src.len and lexer.src[lexer.pos] != '\n': discard lexer.read()

proc comment(lexer: Lexer) =
  lexer.mark()
  discard lexer.read(); discard lexer.read(); discard lexer.read()
  while lexer.pos < lexer.src.len:
    if lexer.pos + 2 < lexer.src.len and lexer.src[lexer.pos] == '-' and lexer.src[lexer.pos + 1] == '-' and lexer.src[lexer.pos + 2] == '-':
      discard lexer.read(); discard lexer.read(); discard lexer.read(); return
    discard lexer.read()
  lexer.diag.emit(Code.Unterminated, lexer.span(), "unterminated multiline comment")

proc stringLiteral(lexer: Lexer; raw = false): Token =
  lexer.mark()
  if raw:
    discard lexer.read(); discard lexer.read(); discard lexer.read()
  discard lexer.read()
  var text = ""
  var reported = false
  while lexer.pos < lexer.src.len and lexer.src[lexer.pos] != '"':
    if lexer.src[lexer.pos] == '\n':
      lexer.diag.emit(Code.Unterminated, lexer.span(), "unterminated string")
      reported = true
      break
    if not raw and lexer.src[lexer.pos] == '\\':
      discard lexer.read()
      if lexer.pos >= lexer.src.len or lexer.src[lexer.pos] == '\n': break
      let escaped = lexer.read()
      case escaped
      of 'n': text.add('\n')
      of 't': text.add('\t')
      of 'r': text.add('\r')
      of '\\': text.add('\\')
      of '"': text.add('"')
      of '0': text.add('\0')
      else:
        lexer.diag.emit(Code.InvalidEscape, lexer.span(), "invalid escape sequence \\" & $escaped)
        text.add(escaped)
    else: text.add(lexer.read())
  if lexer.pos < lexer.src.len and lexer.src[lexer.pos] == '"': discard lexer.read()
  elif not reported: lexer.diag.emit(Code.Unterminated, lexer.span(), "unterminated string")
  make(lexer, Kind.String, text)

proc characterLiteral(lexer: Lexer): Token =
  lexer.mark(); discard lexer.read()
  var text = ""
  if lexer.pos < lexer.src.len and lexer.src[lexer.pos] == '\\':
    discard lexer.read()
    if lexer.pos < lexer.src.len:
      let escaped = lexer.read()
      case escaped
      of 'n': text = "\n"
      of 't': text = "\t"
      of 'r': text = "\r"
      of '\\': text = "\\"
      of '\'': text = "'"
      of '0': text = "\0"
      else:
        lexer.diag.emit(Code.InvalidEscape, lexer.span(), "invalid escape sequence \\" & $escaped)
        text = $escaped
  elif lexer.pos < lexer.src.len and lexer.src[lexer.pos] != '\'': text = $(lexer.read())
  if text.len != 1: lexer.diag.emit(Code.Invalid, lexer.span(), "A character needs exactly one Unicode scalar")
  if lexer.pos < lexer.src.len and lexer.src[lexer.pos] == '\'': discard lexer.read()
  else: lexer.diag.emit(Code.Unterminated, lexer.span(), "unterminated character literal")
  make(lexer, Kind.Char, text)

proc numberLiteral(lexer: Lexer): Token =
  lexer.mark()
  var text = ""
  while lexer.pos < lexer.src.len and (digit(lexer.src[lexer.pos]) or lexer.src[lexer.pos] == '_'):
    if lexer.src[lexer.pos] != '_': text.add(lexer.read()) else: discard lexer.read()
  var real = false
  if lexer.pos + 1 < lexer.src.len and lexer.src[lexer.pos] == '.' and digit(lexer.src[lexer.pos + 1]):
    real = true; text.add(lexer.read())
    while lexer.pos < lexer.src.len and (digit(lexer.src[lexer.pos]) or lexer.src[lexer.pos] == '_'):
      if lexer.src[lexer.pos] != '_': text.add(lexer.read()) else: discard lexer.read()
  let spelling = lexer.src[lexer.start ..< lexer.pos]
  if spelling.contains("__") or spelling.endsWith('_') or spelling.contains("_.") or spelling.contains("._"):
    lexer.diag.emit(Code.Digit, lexer.span(), "Place underscores between digits")
  make(lexer, (if real: Kind.Float else: Kind.Int), text)

proc keywordKind(text: string): Kind =
  case text
  of "module": Module
  of "constant": Constant
  of "dynamic", "mutable": Mutable
  of "is": Is
  of "give": Give
  of "when": When
  of "otherwise": Otherwise
  of "for": For
  of "each": Each
  of "in": In
  of "while": While
  of "repeat": Repeat
  of "until": Until
  of "reaches": Reaches
  of "advance": Advance
  of "match": Match
  of "case": Case
  of "stop", "break": Break
  of "skip", "continue": Continue
  of "use": Use
  of "public": Public
  of "unsafe": Unsafe
  of "native": Native
  of "evaluate": Evaluate
  of "on": On
  of "leave": Leave
  of "try": Try
  of "fallback", "catch": Catch
  of "after", "cleanup", "finally": After
  of "and": And
  of "or": Or
  of "not": Not
  of "where": Where
  of "of": Of
  of "define", "type": Type
  of "plus": Plus
  of "subtract", "minus": Minus
  of "multiply", "times": Times
  of "divide", "divided": Divided
  of "by": By
  of "equals": Equals
  of "does": Does
  of "equal": Equal
  of "greater": Greater
  of "than": Than
  of "less": Less
  of "at": At
  of "least": Least
  of "most": Most
  of "integer": Integer
  of "unsigned": Unsigned
  of "decimal": Decimal
  of "boolean": Boolean
  of "byte": Byte
  of "character": Character
  of "text": Text
  of "array": Array
  of "sequence": Sequence
  of "nothing": Nothing
  of "record": Record
  of "choice": Choice
  of "packed": Packed
  of "union": Union
  of "opaque": Opaque
  of "vector": Vector
  of "function": Function
  of "true": True
  of "false": False
  of "uninitialized": Uninitialized
  of "unreachable": Unreachable
  of "optional": Optional
  of "pointer": Pointer
  of "to": To
  of "address": Address
  of "reference": Reference
  of "start": Start
  of "newline": Newline
  of "anything": Anything
  of "test": Test
  of "context": Context
  of "eval": Eval
  of "reflect": Reflect
  of "embed": Embed
  of "derives": Derives
  of "asm": Asm
  else: Ident

proc word(lexer: Lexer): Token =
  lexer.mark()
  var text = ""
  while lexer.pos < lexer.src.len and (alnum(lexer.src[lexer.pos]) or lexer.src[lexer.pos] == '_'): text.add(lexer.read())
  make(lexer, keywordKind(text), text)

proc blockToken(lexer: Lexer; kind: Kind; substrate: string = ""; header = ""): Token =
  lexer.mark()
  while lexer.pos < lexer.src.len and lexer.src[lexer.pos] != '{': discard lexer.read()
  if lexer.pos < lexer.src.len: discard lexer.read()
  var depth = 1
  var quote = '\0'
  var escaped = false
  var body = ""
  while lexer.pos < lexer.src.len:
    let ch = lexer.read()
    if quote != '\0':
      body.add(ch)
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == quote: quote = '\0'
      continue
    if ch == '"' or ch == '\'': quote = ch; body.add(ch); continue
    if ch == '/' and lexer.pos < lexer.src.len and lexer.src[lexer.pos] == '/':
      body.add(ch)
      while lexer.pos < lexer.src.len and lexer.src[lexer.pos] != '\n': body.add(lexer.read())
      continue
    if ch == '/' and lexer.pos < lexer.src.len and lexer.src[lexer.pos] == '*':
      body.add(ch); body.add(lexer.read())
      while lexer.pos < lexer.src.len and not (lexer.src[lexer.pos] == '*' and lexer.pos + 1 < lexer.src.len and lexer.src[lexer.pos + 1] == '/'):
        body.add(lexer.read())
      if lexer.pos < lexer.src.len:
        body.add(lexer.read())
        body.add(lexer.read())
      continue
    if ch == '{': inc depth; body.add(ch); continue
    if ch == '}':
      dec depth
      if depth == 0:
        var tok = make(lexer, kind, body)
        if substrate.len > 0: tok.native = some(NativeInfo(substrate: substrate,
          header: if header.len > 0: some(header) else: none(string)))
        return tok
    body.add(ch)
  lexer.diag.emit(Code.Unterminated, lexer.span(), "unterminated native block")
  make(lexer, kind, body)

proc symbol(lexer: Lexer): Token =
  lexer.mark(); let ch = lexer.read()
  if ch == '#' and lexer.pos < lexer.src.len and lexer.src[lexer.pos] == '[':
    discard lexer.read(); return make(lexer, Kind.HashBracket, "#[")
  let kind = case ch
    of '{': Kind.Open
    of '}': Kind.Shut
    of '(': Kind.Paren
    of ')': Kind.Close
    of '[': Kind.Square
    of ']': Kind.Bracket
    of '.': Kind.Dot
    of ',': Kind.Comma
    of ':': Kind.Colon
    else:
      lexer.diag.emit(Code.Unexpected, lexer.span(), "unexpected character '" & $ch & "'")
      Kind.Broken
  make(lexer, kind, $ch)

proc next(lexer: Lexer): Token =
  lexer.skip()
  if lexer.pos >= lexer.src.len:
    lexer.mark(); return make(lexer, Kind.Eof, "")
  let ch = lexer.src[lexer.pos]
  if lexer.src[lexer.pos .. ^1].startsWith("native") and lexer.pos + 6 < lexer.src.len and lexer.src[lexer.pos + 6].isSpaceAscii:
    var cursor = lexer.pos + 6
    while cursor < lexer.src.len and lexer.src[cursor].isSpaceAscii: inc cursor
    var substrate = "foo"
    var kind = Kind.Native
    if cursor < lexer.src.len:
      for candidate in ["zig", "c", "asm"]:
        if lexer.src[cursor .. ^1].startsWith(candidate) and cursor + candidate.len < lexer.src.len and
            (lexer.src[cursor + candidate.len].isSpaceAscii or lexer.src[cursor + candidate.len] == '{'):
          substrate = candidate
          if substrate == "zig": kind = Kind.NativeZig
          cursor += candidate.len
          while cursor < lexer.src.len and lexer.src[cursor].isSpaceAscii: inc cursor
          break
    var header = ""
    if cursor < lexer.src.len and lexer.src[cursor .. ^1].startsWith("function") and
        cursor + 8 < lexer.src.len and lexer.src[cursor + 8].isSpaceAscii:
      let opening = lexer.src.find('{', cursor + 8)
      if opening >= 0:
        header = lexer.src[cursor ..< opening].strip()
        cursor = opening
    if cursor < lexer.src.len and lexer.src[cursor] == '{':
      return blockToken(lexer, kind, substrate, header)
  if lexer.src[lexer.pos .. ^1].startsWith("asm") and lexer.pos + 3 < lexer.src.len and
      (lexer.src[lexer.pos + 3].isSpaceAscii or lexer.src[lexer.pos + 3] == '{'):
    var cursor = lexer.pos + 3
    while cursor < lexer.src.len and lexer.src[cursor].isSpaceAscii: inc cursor
    if cursor < lexer.src.len and lexer.src[cursor] == '{': return blockToken(lexer, Kind.Asm)
  if ch == '\n': lexer.mark(); discard lexer.read(); return make(lexer, Kind.NewlineToken, "\n")
  if ch == '-' and lexer.pos + 2 < lexer.src.len and lexer.src[lexer.pos + 1] == '-' and lexer.src[lexer.pos + 2] == '-': lexer.comment(); return lexer.next()
  if ch == '-' and lexer.pos + 1 < lexer.src.len and lexer.src[lexer.pos + 1] == '-': lexer.scanline(); return lexer.next()
  if lexer.src[lexer.pos .. ^1].startsWith("raw\""): return stringLiteral(lexer, true)
  if ch == '"': return stringLiteral(lexer)
  if ch == '\'': return characterLiteral(lexer)
  if digit(ch): return numberLiteral(lexer)
  if letter(ch) or ch == '_': return word(lexer)
  symbol(lexer)

proc lex*(lexer: Lexer; lossless = false): seq[Token] =
  var ending = 0
  while true:
    var tok = lexer.next()
    if lossless:
      tok.leading = some(lexer.src[ending ..< tok.span.start])
      tok.raw = some(lexer.src[tok.span.start ..< tok.span.`end`])
    ending = tok.span.`end`
    result.add(tok)
    if tok.kind == Kind.Eof: break
