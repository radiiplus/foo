import std/[options, os, strutils]
import ../lex/token
import ../lex/kind
import ../lex/lexer
import ../diag/engine
import ../diag/code
import ../diag/span
import ../ast/node
import ../sema/bindings

type Parser* = ref object
  tokens: seq[Token]
  pos: int
  diagnostics: Engine
  start: int

proc newParser*(tokens: seq[Token]; diagnostics: Engine): Parser = Parser(tokens: tokens, diagnostics: diagnostics)
proc peek(parser: Parser; offset = 0): Token =
  if parser.pos + offset < parser.tokens.len: parser.tokens[parser.pos + offset] else: parser.tokens[^1]
proc check(parser: Parser; kind: Kind): bool = parser.peek.kind == kind
proc advance(parser: Parser): Token =
  result = parser.peek
  if parser.pos < parser.tokens.len: inc parser.pos
proc match(parser: Parser; kind: Kind): bool =
  if parser.check(kind):
    discard parser.advance()
    true
  else: false
proc mark(parser: Parser) = parser.start = parser.pos
proc span(parser: Parser): Span =
  let first = parser.tokens[min(parser.start, parser.tokens.high)].span
  let last = parser.tokens[max(0, min(parser.pos - 1, parser.tokens.high))].span
  Span(start: first.start, `end`: last.`end`, line: first.line, col: first.col, file: first.file)
proc expect(parser: Parser; kind: Kind; message: string): Token =
  if parser.check(kind): return parser.advance
  parser.diagnostics.emit(Code.Syntax, parser.peek.span, message)
  parser.advance

proc name(parser: Parser): Name =
  let token = if parser.check(Kind.Sequence) or parser.check(Kind.Text): parser.advance
    else: parser.expect(Kind.Ident, "expected an identifier")
  Name(tag: "name", span: token.span, text: token.text)

proc lines(parser: Parser) =
  while parser.match(Kind.NewlineToken): discard

proc generics(parser: Parser): seq[TypeParam] =
  if not parser.match(Kind.Square): return @[]
  parser.lines()
  while not parser.check(Kind.Bracket) and not parser.check(Kind.Eof):
    let parameterName = parser.name
    var bound: Name
    if parser.match(Kind.Colon): bound = parser.name
    result.add(TypeParam(tag: "type-param", span: parameterName.span, name: parameterName, bound: bound))
    parser.lines()
    if not parser.match(Kind.Comma): break
    parser.lines()
  discard parser.expect(Kind.Bracket, "expected ']'")

proc constraints(parser: Parser): seq[Constraint] =
  if not parser.match(Kind.Where): return @[]
  parser.lines()
  while true:
    let subject = parser.name
    discard parser.expect(Kind.Is, "expected 'is'")
    let trait = parser.name
    result.add(Constraint(tag: "constraint", span: subject.span, subject: subject, trait: trait))
    parser.lines()
    if not parser.match(Kind.Comma): break
    parser.lines()

proc attributes(parser: Parser): seq[string] =
  while parser.match(Kind.HashBracket):
    let attribute = parser.advance
    var value = attribute.text
    if parser.match(Kind.Paren):
      let argument = parser.advance
      value.add("(" & (if argument.kind == Kind.String: "\"" & argument.text & "\"" else: argument.text) & ")")
      discard parser.expect(Kind.Close, "expected ')'")
    result.add(value)
    discard parser.expect(Kind.Bracket, "expected ']'")
    parser.lines()

proc parseType(parser: Parser): `Type` =
  let token = parser.peek
  case token.kind
  of Kind.Integer, Kind.Unsigned, Kind.Decimal:
    discard parser.advance
    var width = ""
    if parser.check(Kind.Int):
      let size = parser.advance
      width = size.text
      if width == "64":
        parser.diagnostics.emit(Code.Syntax, size.span,
          "Use bare '" & token.text & "' for the canonical 64-bit type")
    return Primitive(tag: "primitive", span: token.span, name: token.text, width: width)
  of Kind.Boolean, Kind.Byte, Kind.Character, Kind.Text, Kind.Nothing:
    discard parser.advance
    return Primitive(tag: "primitive", span: token.span, name: token.text)
  of Kind.Sequence:
    discard parser.advance
    discard parser.expect(Kind.Of, "expected 'of'")
    let constant = parser.match(Kind.Constant)
    return Sequence(tag: "sequence", span: token.span, elem: parser.parseType, constant: constant)
  of Kind.Optional:
    discard parser.advance
    return Optional(tag: "optional", span: token.span, elem: parser.parseType)
  of Kind.Pointer:
    discard parser.advance
    discard parser.expect(Kind.To, "expected 'to'")
    return Pointer(tag: "pointer", span: token.span, elem: parser.parseType)
  of Kind.Vector:
    discard parser.advance
    discard parser.expect(Kind.Square, "expected '['")
    parser.lines()
    let length = parser.expect(Kind.Int, "expected vector lane count")
    discard parser.expect(Kind.Comma, "expected ','")
    parser.lines()
    let elem = parser.parseType
    parser.lines()
    discard parser.expect(Kind.Bracket, "expected ']'")
    return Vector(tag: "vector", span: token.span, length: length.text, elem: elem)
  of Kind.Function:
    discard parser.advance
    if parser.check(Kind.Ident) and parser.peek.text == "taking":
      discard parser.advance
    var params: seq[`Type`]
    if parser.peek(-1).text == "taking":
      discard parser.expect(Kind.Paren, "expected '('")
      parser.lines()
      if parser.check(Kind.Close):
        parser.diagnostics.emit(Code.Syntax, token.span,
          "Write 'function giving' for a function type with no parameters")
      while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
        params.add(parser.parseType)
        parser.lines()
        if not parser.match(Kind.Comma): break
        parser.lines()
      discard parser.expect(Kind.Close, "expected ')'")
    if parser.check(Kind.Ident) and parser.peek.text == "giving":
      discard parser.advance
    else:
      discard parser.expect(Kind.Ident, "expected 'giving'")
    let ret = parser.parseType
    var abi = ""
    if parser.match(Kind.For): abi = parser.name.text
    return FunctionType(tag: "function-type", span: token.span, params: params, ret: ret, abi: abi)
  of Kind.Ident:
    discard parser.advance
    if token.text == "failable": return Error(tag: "error", span: token.span, elem: parser.parseType)
    let typeName = Name(tag: "name", span: token.span, text: token.text)
    while parser.check(Kind.Dot) and parser.peek(1).kind == Kind.Ident and
        parser.peek.span.`end` == parser.peek(1).span.start:
      discard parser.advance
      typeName.text.add("." & parser.name.text)
    if parser.match(Kind.Square):
      var args: seq[`Type`]
      parser.lines()
      while not parser.check(Kind.Bracket) and not parser.check(Kind.Eof):
        args.add(parser.parseType)
        parser.lines()
        if not parser.match(Kind.Comma): break
        parser.lines()
      discard parser.expect(Kind.Bracket, "expected ']'")
      return GenericInst(tag: "generic-inst", span: token.span, name: typeName, args: args)
    return Named(tag: "named", span: token.span, name: typeName)
  else:
    parser.diagnostics.emit(Code.Syntax, token.span, "expected a type")
    discard parser.advance
    return Broken(tag: "broken", span: token.span)

proc expression(parser: Parser; minPrec = 0): Expression
proc blockNode(parser: Parser): Block

proc beginsExpression(parser: Parser; offset = 0): bool =
  parser.peek(offset).kind in [Kind.Ident, Kind.String, Kind.Int, Kind.Float,
    Kind.Char, Kind.True, Kind.False, Kind.Nothing, Kind.Null, Kind.Paren, Kind.Reflect,
    Kind.Embed, Kind.Uninitialized, Kind.Unreachable, Kind.Newline]

proc beginsNamedArgument(parser: Parser): bool =
  parser.check(Kind.Ident) and parser.peek(1).kind != Kind.Paren and
    parser.beginsExpression(1) and parser.peek(1).text != "remainder"

proc parameter(parser: Parser; allowExtended = true): Parameter =
  var variadic = false
  if allowExtended and parser.check(Kind.Each):
    discard parser.advance
    variadic = true
  let parameterName = parser.name
  if allowExtended and parser.match(Kind.Are): variadic = true
  var parameterType = parser.parseType
  if variadic and parameterType != nil and parameterType.tag == "sequence":
    parameterType = node.Sequence(parameterType).elem
  var defaultValue: Expression
  if allowExtended:
    if parser.check(Kind.Ident) and parser.peek.text == "default":
      discard parser.advance
      defaultValue = parser.expression()
  Parameter(tag: "parameter", span: parameterName.span, name: parameterName,
    `type`: parameterType, default: defaultValue, variadic: variadic)

proc machineStart(parser: Parser): bool =
  let word = parser.peek.text
  let next = parser.peek(1).text
  (word == "atomic" and next == "add") or
    (word == "bits" and next in ["set", "clear"]) or
    (word == "memory" and next == "align") or
    (word == "register" and parser.peek(2).kind == Kind.Is) or
    (word == "call" and next == "system")

proc takeWord(parser: Parser; word: string) =
  let token = parser.advance
  if token.text != word:
    parser.diagnostics.emit(Code.Syntax, token.span, "expected '" & word & "'")

proc functionOptions(parser: Parser; attributes: var seq[string]; abi: var string) =
  while true:
    parser.lines()
    if parser.match(Kind.For):
      let role = parser.name.text
      case role
      of "startup": attributes.add("start")
      of "interrupt": attributes.add("interrupt")
      else: abi = role
    elif parser.check(Kind.Ident) and parser.peek.text == "without":
      discard parser.advance
      parser.takeWord("setup")
      attributes.add("naked")
    elif parser.check(Kind.Ident) and parser.peek.text == "using":
      discard parser.advance
      parser.takeWord("feature")
      let feature = parser.expect(Kind.String, "expected a target feature name")
      attributes.add("target_feature(\"" & feature.text & "\")")
    elif parser.check(Kind.Ident) and parser.peek.text == "keeping":
      discard parser.advance
      parser.takeWord("call")
      attributes.add("noinline")
    else:
      break

proc machine(parser: Parser): Machine =
  let first = parser.advance
  if first.text == "call":
    parser.takeWord("system")
    parser.takeWord("call")
    let value = parser.expression(2)
    var args: seq[Expression]
    if parser.peek.text == "with":
      discard parser.advance
      args.add(parser.expression(2))
      while parser.match(Kind.Comma): args.add(parser.expression(2))
    return Machine(tag: "machine", span: first.span, operation: "system", value: value, args: args)
  if first.text == "register":
    let register = parser.advance.text
    parser.takeWord("is")
    return Machine(tag: "machine", span: first.span, operation: "register", register: register, value: parser.expression)
  let operation =
    if first.text == "atomic": "atomic"
    elif first.text == "memory": "align"
    else: parser.peek.text
  discard parser.advance
  let target = parser.name
  if operation == "atomic": parser.takeWord("by")
  elif operation == "align": parser.takeWord("to")
  else:
    parser.takeWord("at")
    parser.takeWord("position")
  Machine(tag: "machine", span: first.span, operation: operation, target: target, value: parser.expression)

proc primary(parser: Parser): Expression =
  if parser.machineStart: return parser.machine
  let token = parser.advance
  case token.kind
  of Kind.Function:
    var params: seq[Parameter]
    if parser.match(Kind.Paren):
      parser.lines()
      if parser.check(Kind.Close):
        parser.diagnostics.emit(Code.Syntax, token.span,
          "Remove empty parentheses from a function with no parameters")
      while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
        params.add(parser.parameter())
        parser.lines()
        if not parser.match(Kind.Comma): break
        parser.lines()
      discard parser.expect(Kind.Close, "expected ')'")
    var returnType: `Type`
    if parser.check(Kind.Ident) and parser.peek.text == "giving":
      discard parser.advance
      returnType = parser.parseType
    var captures: seq[Name]
    if parser.check(Kind.Ident) and parser.peek.text == "using":
      discard parser.advance
      discard parser.expect(Kind.Paren, "expected '('")
      while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
        captures.add(parser.name)
        if not parser.match(Kind.Comma): break
      discard parser.expect(Kind.Close, "expected ')'")
    Closure(tag: "closure", span: token.span, params: params,
      returnType: returnType, captures: captures, body: parser.blockNode)
  of Kind.Int:
    Integer(tag: "integer", span: token.span, value: token.text, spelling: token.spelling)
  of Kind.Float: Decimal(tag: "decimal", span: token.span, value: token.text, spelling: token.spelling)
  of Kind.String: Text(tag: "text", span: token.span, value: token.text)
  of Kind.Char: Character(tag: "character", span: token.span, value: token.text)
  of Kind.True: `True`(tag: "true", span: token.span)
  of Kind.False: `False`(tag: "false", span: token.span)
  of Kind.Nothing: Nothing(tag: "nothing", span: token.span)
  of Kind.Null: Null(tag: "null", span: token.span)
  of Kind.Uninitialized: Uninitialized(tag: "uninitialized", span: token.span)
  of Kind.Unreachable: Unreachable(tag: "unreachable", span: token.span)
  of Kind.Ident, Kind.Text, Kind.Sequence: Name(tag: "name", span: token.span, text: token.text)
  of Kind.Newline: NewlineExpr(tag: "newline", span: token.span)
  of Kind.Paren:
    let value = parser.expression()
    discard parser.expect(Kind.Close, "expected ')'")
    Group(tag: "group", span: token.span, expr: value)
  of Kind.Reflect:
    discard parser.expect(Kind.Square, "expected '['")
    let valueType = parser.parseType
    discard parser.expect(Kind.Bracket, "expected ']'")
    if parser.match(Kind.Paren):
      parser.diagnostics.emit(Code.Syntax, token.span,
        "Remove empty parentheses from a call with no arguments")
      discard parser.expect(Kind.Close, "expected ')'")
    Reflect(tag: "reflect", span: token.span, `type`: valueType)
  of Kind.Embed:
    var valueType: `Type`
    if parser.match(Kind.Square):
      valueType = parser.parseType
      discard parser.expect(Kind.Bracket, "expected ']'")
    discard parser.expect(Kind.Paren, "expected '('")
    let path = parser.expect(Kind.String, "expected path string")
    discard parser.expect(Kind.Close, "expected ')'")
    Embed(tag: "embed", span: token.span, path: path.text, `type`: valueType)
  else:
    parser.diagnostics.emit(Code.Syntax, token.span, "expected an expression")
    Broken(tag: "broken", span: token.span)

proc renamed(callee: Expression; name: string): Expression =
  if callee.tag == "field":
    let field = Field(callee)
    return Field(tag: "field", span: callee.span, `object`: field.`object`,
      field: Name(tag: "name", span: field.field.span, text: name))
  let original = Name(callee)
  let separator = original.text.rfind('.')
  let text = if separator >= 0: original.text[0 .. separator] & name else: name
  Name(tag: "name", span: original.span, text: text)

proc sentence(parser: Parser; callee: Expression): Expression =
  if callee.tag notin ["name", "field"]: return callee
  let qualified = if callee.tag == "name": Name(callee).text else: Field(callee).field.text
  let separator = qualified.rfind('.')
  let word = if separator >= 0: qualified[separator + 1 .. ^1] else: qualified
  let next = parser.peek.text
  let argument = parser.peek.kind in [Kind.Ident, Kind.String, Kind.Int, Kind.Float,
    Kind.True, Kind.False, Kind.Paren]
  if parser.peek.kind in [Kind.Dot, Kind.Comma, Kind.Close, Kind.Bracket, Kind.Open,
      Kind.Shut, Kind.NewlineToken, Kind.Eof, Kind.Catch]: return callee
  if next in ["into", "with", "to", "in", "from", "remainder"]: return callee

  proc value(): Expression = parser.expression(2)
  var name = word
  var args: seq[Expression]
  var names: seq[string]
  var recognized = true
  if word == "current" and next == "time":
    parser.takeWord("time")
    args = @[]
  elif word == "length" and next == "of":
    parser.takeWord("of")
    args = @[value()]
  elif word == "read" and next == "line":
    parser.takeWord("line")
    name = "line"
    if parser.peek.text == "from":
      parser.takeWord("from")
      args = @[value()]
    else:
      args = @[Expression(Call(tag: "call", span: callee.span, callee: renamed(callee, "input"), args: @[]))]
  elif word in ["read", "open"] and next == "file":
    parser.takeWord("file")
    args = @[value()]
    if word == "open": args.add(Text(tag: "text", span: callee.span, value: "read"))
  elif word == "write" and next == "file":
    parser.takeWord("file")
    let path = value()
    parser.takeWord("with")
    args = @[path, value()]
  elif word == "create" and next == "directory":
    parser.takeWord("directory")
    name = "directory"
    args = @[value()]
  elif word in ["read", "receive"] and next == "from":
    parser.takeWord("from")
    let stream = value()
    parser.takeWord("with")
    args = @[stream, value()]
  elif word in ["copy", "compare", "concatenate", "join", "split", "map", "filter"] and argument:
    let first = value()
    parser.takeWord(if word == "copy": "into" else: "with")
    args = @[first, value()]
    if word == "copy": name = "transfer"
  elif word in ["write", "send", "append"] and argument:
    let content = value()
    parser.takeWord("to")
    args = @[value(), content]
  elif word == "find" and argument:
    let item = value()
    parser.takeWord("in")
    args = @[value(), item]
  elif word == "remove" and next == "at":
    parser.takeWord("at")
    let index = value()
    parser.takeWord("from")
    args = @[value(), index]
  elif word in ["connect", "listen"] and next == (if word == "connect": "to" else: "on"):
    discard parser.advance
    let host = value()
    parser.takeWord("with")
    args = @[host, value()]
  elif word in ["wait", "sleep"] and next == "for":
    parser.takeWord("for")
    args = @[value()]
  elif (word == "run" and next == "command") or (word == "spawn" and next == "task") or
      (word == "lock" and next == "mutex") or (word == "signal" and next == "condition") or
      (word == "accept" and next == "connection") or (word == "measure" and next == "duration"):
    discard parser.advance
    args = @[value()]
  elif word == "get" and next in ["argument", "environment"]:
    name = parser.advance.text
    if name == "environment": parser.takeWord("variable")
    args = @[value()]
  elif word == "log" and next in ["message", "error"]:
    name = parser.advance.text
    args = @[value()]
    if callee.tag == "name" and '.' notin Name(callee).text:
      return Call(tag: "call", span: callee.span,
        callee: Name(tag: "name", span: callee.span, text: "__bare_log." & name), args: args)
  elif word in ["display", "clear", "trim", "sort", "release", "unlock"] and argument:
    args = @[value()]
  elif parser.beginsExpression:
    while parser.beginsExpression:
      var label = ""
      if parser.beginsNamedArgument:
        label = parser.advance.text
      args.add(parser.expression(5))
      names.add(label)
  else:
    recognized = false
  if not recognized: return callee
  let ending = parser.peek(-1).span.`end`
  let callSpan = Span(start: callee.span.start, `end`: ending, line: callee.span.line,
    col: callee.span.col, file: callee.span.file)
  if args.len > 0 and args[^1].tag == "unary" and Unary(args[^1]).op == "try":
    args[^1] = Unary(args[^1]).operand
    let call = Call(tag: "call", span: callSpan, callee: renamed(callee, name), args: args)
    return Unary(tag: "unary", span: callSpan, op: "try", operand: call)
  Call(tag: "call", span: callSpan, callee: renamed(callee, name), args: args,
    names: names)

proc postfix(parser: Parser): Expression =
  result = parser.primary
  while true:
    if parser.match(Kind.Paren):
      if parser.check(Kind.Close):
        parser.diagnostics.emit(Code.Syntax, result.span,
          "Remove empty parentheses from a call with no arguments")
      var args: seq[Expression]
      var names: seq[string]
      var sawNamed = false
      while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
        var argumentName = ""
        if parser.beginsNamedArgument:
          argumentName = parser.advance.text
          sawNamed = true
        elif sawNamed:
          parser.diagnostics.emit(Code.Syntax, parser.peek.span,
            "positional arguments must come before named arguments")
        args.add(parser.expression())
        names.add(argumentName)
        if not parser.match(Kind.Comma): break
      let closing = parser.expect(Kind.Close, "expected ')'")
      result = Call(tag: "call", span: Span(start: result.span.start,
        `end`: closing.span.`end`, line: result.span.line, col: result.span.col,
        file: result.span.file), callee: result, args: args, names: names)
    elif parser.check(Kind.Dot) and parser.peek(1).kind == Kind.Ident and parser.peek.span.`end` == parser.peek(1).span.start:
      discard parser.advance
      let field = parser.name
      result = Field(tag: "field", span: Span(start: result.span.start,
        `end`: field.span.`end`, line: result.span.line, col: result.span.col,
        file: result.span.file), `object`: result, field: field)
    elif parser.match(Kind.Square):
      var closingPosition = parser.pos
      var depth = 1
      while closingPosition < parser.tokens.len and depth > 0:
        if parser.tokens[closingPosition].kind == Kind.Square: inc depth
        elif parser.tokens[closingPosition].kind == Kind.Bracket: dec depth
        inc closingPosition
      if depth == 0:
        var types: seq[`Type`]
        while not parser.check(Kind.Bracket) and not parser.check(Kind.Eof):
          types.add(parser.parseType)
          if not parser.match(Kind.Comma): break
        discard parser.expect(Kind.Bracket, "expected ']'")
        var args: seq[Expression]
        var ending = parser.peek(-1).span.`end`
        if parser.match(Kind.Paren):
          if parser.check(Kind.Close):
            parser.diagnostics.emit(Code.Syntax, result.span,
              "Remove empty parentheses from a call with no arguments")
          while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
            args.add(parser.expression)
            if not parser.match(Kind.Comma): break
          ending = parser.expect(Kind.Close, "expected ')'").span.`end`
        result = Call(tag: "call", span: Span(start: result.span.start,
          `end`: ending, line: result.span.line, col: result.span.col,
          file: result.span.file), callee: result, args: args, types: types)
      else:
        parser.diagnostics.emit(Code.Syntax, parser.peek.span,
          "Index a value with 'at', for example 'items at index'")
        discard parser.expression()
        discard parser.expect(Kind.Bracket, "expected ']'")
    elif parser.match(Kind.At):
      let index = parser.primary
      result = Index(tag: "index", span: result.span, `object`: result, index: index)
    else: break
  result = parser.sentence(result)
  while parser.match(Kind.Try):
    result = Unary(tag: "unary", span: result.span, op: "try", operand: result)

proc unary(parser: Parser): Expression =
  var ordinaryCall = false
  if parser.check(Kind.Ident) and parser.peek.text == "allocate" and
      parser.peek(1).kind == Kind.Paren:
    var depth = 0
    var index = parser.pos + 1
    while index < parser.tokens.len:
      let kind = parser.tokens[index].kind
      if kind == Kind.Paren: inc depth
      elif kind == Kind.Close:
        dec depth
        if depth == 0: break
      elif kind == Kind.Comma and depth == 1:
        ordinaryCall = true
        break
      inc index
  if parser.check(Kind.Ident) and parser.peek.text == "allocate" and not ordinaryCall:
    let token = parser.advance
    let size = parser.primary
    var owner: Expression
    if parser.check(Kind.Ident) and parser.peek.text == "using":
      discard parser.advance
      owner = parser.primary
    var value: Expression = Allocation(tag: "allocation", span: token.span, size: size, owner: owner)
    while parser.match(Kind.Try):
      value = Unary(tag: "unary", span: value.span, op: "try", operand: value)
    return value
  if parser.check(Kind.Not):
    let token = parser.advance
    return Unary(tag: "unary", span: token.span, op: token.text, operand: parser.unary)
  parser.postfix

proc binop(parser: Parser): string =
  case parser.peek.kind
  of Kind.Plus: discard parser.advance; "plus"
  of Kind.Minus: discard parser.advance; "minus"
  of Kind.Times: discard parser.advance; "times"
  of Kind.Divided:
    let token = parser.advance
    if token.text == "divided": discard parser.expect(Kind.By, "expected 'by'")
    "divided by"
  of Kind.Is:
    discard parser.advance
    if parser.match(Kind.Greater):
      discard parser.expect(Kind.Than, "expected 'than'")
      if parser.match(Kind.Or):
        discard parser.expect(Kind.Equal, "expected 'equal'")
        discard parser.expect(Kind.To, "expected 'to'")
        "is at least"
      else: "is greater than"
    elif parser.match(Kind.Less):
      discard parser.expect(Kind.Than, "expected 'than'")
      if parser.match(Kind.Or):
        discard parser.expect(Kind.Equal, "expected 'equal'")
        discard parser.expect(Kind.To, "expected 'to'")
        "is at most"
      else: "is less than"
    elif parser.match(Kind.At):
      if parser.match(Kind.Least): "is at least"
      elif parser.match(Kind.Most): "is at most"
      else: "equals"
    elif parser.match(Kind.Not): "does not equal"
    else: "equals"
  of Kind.Greater:
    discard parser.advance
    discard parser.expect(Kind.Than, "expected 'than'")
    if parser.match(Kind.Or):
      discard parser.expect(Kind.Equal, "expected 'equal'")
      discard parser.expect(Kind.To, "expected 'to'")
      "is at least"
    else: "is greater than"
  of Kind.Less:
    discard parser.advance
    discard parser.expect(Kind.Than, "expected 'than'")
    if parser.match(Kind.Or):
      discard parser.expect(Kind.Equal, "expected 'equal'")
      discard parser.expect(Kind.To, "expected 'to'")
      "is at most"
    else: "is less than"
  of Kind.And: discard parser.advance; "and"
  of Kind.Or: discard parser.advance; "or"
  of Kind.Catch: discard parser.advance; "catch"
  of Kind.Ident:
    if parser.peek.text == "remainder": discard parser.advance; "remainder" else: ""
  else: ""

proc precedence(operation: string): int =
  case operation
  of "catch": 1
  of "or": 2
  of "and": 3
  of "equals", "does not equal", "is greater than", "is less than", "is at least", "is at most": 4
  of "plus", "minus": 5
  of "times", "divided by", "remainder": 6
  else: 0

proc expression(parser: Parser; minPrec = 0): Expression =
  result = parser.unary
  while true:
    let position = parser.pos
    let operation = parser.binop
    if operation.len == 0: break
    let priority = precedence(operation)
    if priority < minPrec:
      parser.pos = position
      break
    let right = parser.expression(if operation == "catch": priority else: priority + 1)
    result = Binary(tag: "binary", span: result.span, op: operation, left: result, right: right)

proc parse*(parser: Parser): Program

proc member(parser: Parser): Member =
  parser.mark()
  var attributes = parser.attributes()
  let fieldName = parser.name
  discard parser.expect(Kind.Of, "expected 'of'")
  discard parser.expect(Kind.Type, "expected 'type'")
  let fieldType = parser.parseType
  if parser.check(Kind.Ident) and parser.peek.text == "with":
    discard parser.advance
    parser.takeWord("exact")
    parser.takeWord("access")
    attributes.add("volatile")
  discard parser.expect(Kind.Dot, "expected '.'")
  Member(tag: "member", span: parser.span, name: fieldName, `type`: fieldType,
    attributes: attributes)

proc recordType(parser: Parser; layout = ""): Record =
  parser.mark()
  discard parser.expect(Kind.Record, "expected 'record'")
  discard parser.expect(Kind.Open, "expected '{'")
  var fields: seq[Member]
  while not parser.check(Kind.Shut) and not parser.check(Kind.Eof):
    if parser.check(Kind.NewlineToken): discard parser.advance; continue
    fields.add(parser.member)
  discard parser.expect(Kind.Shut, "expected '}'")
  Record(tag: "record", span: parser.span, fields: fields, layout: layout)

proc unionType(parser: Parser): Union =
  parser.mark()
  discard parser.expect(Kind.Union, "expected 'union'")
  discard parser.expect(Kind.Open, "expected '{'")
  var fields: seq[Member]
  while not parser.check(Kind.Shut) and not parser.check(Kind.Eof):
    if parser.check(Kind.NewlineToken): discard parser.advance; continue
    fields.add(parser.member)
  discard parser.expect(Kind.Shut, "expected '}'")
  Union(tag: "union", span: parser.span, fields: fields, layout: "c")

proc choiceType(parser: Parser): Choice =
  parser.mark()
  discard parser.expect(Kind.Choice, "expected 'choice'")
  discard parser.expect(Kind.Open, "expected '{'")
  var variants: seq[Variant]
  while not parser.check(Kind.Shut) and not parser.check(Kind.Eof):
    if parser.check(Kind.NewlineToken): discard parser.advance; continue
    let variantName = parser.name
    var payload: `Type`
    var value: Integer
    if parser.match(Kind.Paren):
      payload = parser.parseType
      discard parser.expect(Kind.Close, "expected ')'")
    if parser.match(Kind.Is):
      let integer = parser.expect(Kind.Int, "expected integer value")
      value = Integer(tag: "integer", span: integer.span, value: integer.text, spelling: integer.spelling)
    discard parser.expect(Kind.Dot, "expected '.'")
    variants.add(Variant(tag: "variant", span: variantName.span, name: variantName, value: value, payload: payload))
  discard parser.expect(Kind.Shut, "expected '}'")
  Choice(tag: "choice", span: parser.span, variants: variants)

proc pattern(parser: Parser): Pattern =
  let token = parser.peek
  case token.kind
  of Kind.Anything:
    discard parser.advance
    Wildcard(tag: "wildcard", span: token.span)
  of Kind.Nothing:
    discard parser.advance
    Nothing(tag: "nothing", span: token.span)
  of Kind.Null:
    discard parser.advance
    Null(tag: "null", span: token.span)
  of Kind.Int:
    discard parser.advance
    Integer(tag: "integer", span: token.span, value: token.text, spelling: token.spelling)
  of Kind.True:
    discard parser.advance
    `True`(tag: "true", span: token.span)
  of Kind.False:
    discard parser.advance
    `False`(tag: "false", span: token.span)
  of Kind.Ident:
    var patternName = parser.name
    while parser.check(Kind.Dot) and parser.peek(1).kind == Kind.Ident and
        parser.peek.span.`end` == parser.peek(1).span.start:
      discard parser.advance
      let part = parser.name
      patternName = Name(tag: "name", text: patternName.text & "." & part.text,
        span: Span(start: patternName.span.start, `end`: part.span.`end`,
          line: patternName.span.line, col: patternName.span.col,
          file: patternName.span.file))
    if parser.match(Kind.Paren):
      var binding: Name
      if not parser.check(Kind.Close): binding = parser.name
      discard parser.expect(Kind.Close, "expected ')'")
      VariantPattern(tag: "variant-pattern", span: token.span, name: patternName, binding: binding)
    else: patternName
  else:
    parser.diagnostics.emit(Code.Syntax, token.span, "expected pattern")
    discard parser.advance
    Wildcard(tag: "wildcard", span: token.span)

proc action(parser: Parser): Action =
  parser.mark()
  let actionName = parser.name
  while parser.check(Kind.Dot) and parser.peek(1).kind == Kind.Ident and parser.peek.span.`end` == parser.peek(1).span.start:
    discard parser.advance
    actionName.text.add("." & parser.name.text)
  var args: seq[Expression]
  if parser.match(Kind.Square):
    var types: seq[`Type`]
    while not parser.check(Kind.Bracket) and not parser.check(Kind.Eof):
      types.add(parser.parseType)
      if not parser.match(Kind.Comma): break
    discard parser.expect(Kind.Bracket, "expected ']'")
    if parser.match(Kind.Paren):
      if parser.check(Kind.Close):
        parser.diagnostics.emit(Code.Syntax, actionName.span,
          "Remove empty parentheses from a call with no arguments")
      while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
        args.add(parser.expression)
        if not parser.match(Kind.Comma): break
      discard parser.expect(Kind.Close, "expected ')'")
    var value: Expression = Call(tag: "call", span: parser.span, callee: actionName, args: args, types: types)
    if parser.match(Kind.Try):
      value = Unary(tag: "unary", span: value.span, op: "try", operand: value)
    if parser.match(Kind.Catch):
      value = Binary(tag: "binary", span: parser.span, op: "catch", left: value, right: parser.expression)
    discard parser.expect(Kind.Dot, "expected '.'")
    return Action(tag: "action", span: parser.span, name: actionName, args: @[], value: value)
  elif parser.match(Kind.Paren):
    var names: seq[string]
    if parser.check(Kind.Close):
      parser.diagnostics.emit(Code.Syntax, actionName.span,
        "Remove empty parentheses from a call with no arguments")
    while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
      var label = ""
      if parser.beginsNamedArgument:
        label = parser.advance.text
      args.add(parser.expression)
      names.add(label)
      if not parser.match(Kind.Comma): break
    discard parser.expect(Kind.Close, "expected ')'")
    if parser.match(Kind.Try):
      let call = Call(tag: "call", span: parser.span, callee: actionName,
        args: args, names: names)
      let value = Unary(tag: "unary", span: call.span, op: "try", operand: call)
      discard parser.expect(Kind.Dot, "expected '.'")
      return Action(tag: "action", span: parser.span, name: actionName, args: @[], value: value)
    if parser.match(Kind.Catch):
      let call = Call(tag: "call", span: parser.span, callee: actionName,
        args: args, names: names)
      let value = Binary(tag: "binary", span: parser.span, op: "catch", left: call, right: parser.expression)
      discard parser.expect(Kind.Dot, "expected '.'")
      return Action(tag: "action", span: parser.span, name: actionName, args: @[], value: value)
    let value = Call(tag: "call", span: parser.span, callee: actionName,
      args: args, names: names)
    discard parser.expect(Kind.Dot, "expected '.'")
    return Action(tag: "action", span: parser.span, name: actionName,
      args: @[], value: value)
  else:
    var value = parser.sentence(actionName)
    if value.tag == "name" and (parser.check(Kind.Try) or
        parser.check(Kind.Catch)):
      value = Call(tag: "call", span: value.span, callee: value, args: @[])
    if value.tag in ["call", "unary"]:
      if parser.match(Kind.Try):
        value = Unary(tag: "unary", span: value.span, op: "try", operand: value)
      if parser.match(Kind.Catch):
        value = Binary(tag: "binary", span: parser.span, op: "catch", left: value, right: parser.expression)
      discard parser.expect(Kind.Dot, "expected '.'")
      return Action(tag: "action", span: parser.span, name: actionName, args: @[], value: value)
    while not parser.check(Kind.Dot) and not parser.check(Kind.NewlineToken) and not parser.check(Kind.Shut) and not parser.check(Kind.Eof):
      args.add(parser.expression)
  discard parser.expect(Kind.Dot, "expected '.'")
  Action(tag: "action", span: parser.span, name: actionName, args: args)

proc statement(parser: Parser): Statement =
  parser.mark()
  var attributes = parser.attributes()
  let public = parser.match(Kind.Public)
  let token = parser.peek
  if token.kind == Kind.Ident and token.text == "extern" and parser.peek(1).kind == Kind.String:
    discard parser.advance
    let abiToken = parser.advance
    if abiToken.text != "C": parser.diagnostics.emit(Code.Invalid, abiToken.span, "expected extern \"C\"")
    discard parser.expect(Kind.Function, "expected 'function'")
    let functionName = parser.name
    var params: seq[Parameter]
    if parser.match(Kind.Paren):
      parser.lines()
      if parser.check(Kind.Close):
        parser.diagnostics.emit(Code.Syntax, functionName.span,
          "Remove empty parentheses from a function with no parameters")
      while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
        params.add(parser.parameter(false))
        parser.lines()
        if not parser.match(Kind.Comma): break
        parser.lines()
      discard parser.expect(Kind.Close, "expected ')'")
    parser.lines()
    if parser.peek.text == "giving": discard parser.advance
    else: discard parser.expect(Kind.Ident, "expected 'giving'")
    let returnType = parser.parseType
    if parser.check(Kind.Open):
      return Function(tag: "function", span: parser.span, public: public, abi: "c", name: functionName,
        params: params, returnType: returnType, attributes: attributes, body: parser.blockNode)
    discard parser.expect(Kind.Dot, "expected '.'")
    return ExternFunction(tag: "extern-function", span: parser.span, public: public, abi: "c",
      name: functionName, params: params, returnType: returnType)
  if parser.machineStart:
    let operation = parser.machine
    discard parser.expect(Kind.Dot, "expected '.'")
    return operation
  if token.kind == Kind.Ident and token.text in ["increase", "decrease"]:
    let operation = parser.advance
    let target = parser.name
    parser.takeWord("by")
    let amount = parser.expression
    discard parser.expect(Kind.Dot, "expected '.'")
    return Assignment(tag: "assignment", span: parser.span, target: target,
      value: Binary(tag: "binary", span: operation.span,
        op: if operation.text == "increase": "plus" else: "minus",
        left: Name(tag: "name", span: target.span, text: target.text),
        right: amount))
  case token.kind
  of Kind.Constant:
    discard parser.advance
    let declarationName = parser.name
    if parser.match(Kind.Paren):
      if public:
        parser.diagnostics.emit(Code.Syntax, token.span,
          "record destructuring cannot be public")
      var fields, bindings: seq[Name]
      parser.lines()
      while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
        let field = parser.name
        fields.add(Name(tag: "name", span: field.span, text: field.text))
        bindings.add(field)
        parser.lines()
        if not parser.match(Kind.Comma): break
        parser.lines()
      discard parser.expect(Kind.Close, "expected ')'")
      discard parser.expect(Kind.Is, "expected 'is'")
      let value = parser.expression
      discard parser.match(Kind.Dot)
      return Destructure(tag: "destructure", span: parser.span,
        recordType: Named(tag: "named", span: declarationName.span,
          name: declarationName), fields: fields, bindings: bindings,
        value: value)
    var valueType: `Type`
    if parser.match(Kind.Of): discard parser.match(Kind.Type); valueType = parser.parseType
    let plural = parser.match(Kind.Are)
    if not plural: discard parser.expect(Kind.Is, "expected 'is' or 'are'")
    let value = parser.expression
    discard parser.match(Kind.Dot)
    Constant(tag: "constant", span: parser.span, public: public, plural: plural,
      name: declarationName, `type`: valueType, value: value)
  of Kind.Mutable:
    discard parser.advance
    let declarationName = parser.name
    var valueType: `Type`
    if parser.match(Kind.Of): discard parser.match(Kind.Type); valueType = parser.parseType
    let plural = parser.match(Kind.Are)
    if not plural: discard parser.expect(Kind.Is, "expected 'is' or 'are'")
    let value = parser.expression
    discard parser.match(Kind.Dot)
    Mutable(tag: "mutable", span: parser.span, public: public, plural: plural,
      name: declarationName, `type`: valueType, value: value)
  of Kind.Give:
    discard parser.advance
    var value: Expression
    if not parser.check(Kind.Dot) and not parser.check(Kind.Shut): value = parser.expression
    discard parser.match(Kind.Dot)
    Give(tag: "give", span: parser.span, value: value)
  of Kind.Function:
    discard parser.advance
    let functionName = parser.name
    let typeParams = parser.generics()
    var params: seq[Parameter]
    if parser.match(Kind.Paren):
      parser.lines()
      if parser.check(Kind.Close):
        parser.diagnostics.emit(Code.Syntax, functionName.span,
          "Remove empty parentheses from a function with no parameters")
      while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
        params.add(parser.parameter())
        parser.lines()
        if not parser.match(Kind.Comma): break
        parser.lines()
      discard parser.expect(Kind.Close, "expected ')'")
    parser.lines()
    var guard: Expression
    if parser.match(Kind.When):
      guard = parser.expression
      parser.lines()
    var returnType: `Type`
    if parser.check(Kind.Ident) and parser.peek.text == "giving":
      discard parser.advance
      returnType = parser.parseType
    parser.lines()
    var abi = ""
    parser.functionOptions(attributes, abi)
    let constraints = parser.constraints()
    parser.lines()
    let body = parser.blockNode
    Function(tag: "function", span: parser.span, public: public, name: functionName, typeParams: typeParams,
      params: params, returnType: returnType, abi: abi, constraints: constraints,
      constraint: if constraints.len > 0: constraints[0] else: nil,
      attributes: attributes, guard: guard, body: body)
  of Kind.Start:
    discard parser.advance
    if parser.match(Kind.Paren):
      parser.diagnostics.emit(Code.Syntax, token.span,
        "Remove empty parentheses from start")
      discard parser.expect(Kind.Close, "expected ')'")
    var abi = ""
    parser.functionOptions(attributes, abi)
    Function(tag: "function", span: parser.span, public: public, name: Name(tag: "name", span: token.span, text: "start"), params: @[], abi: abi, attributes: attributes, body: parser.blockNode)
  of Kind.Test:
    discard parser.advance
    let nameToken = parser.expect(Kind.String, "expected a test name")
    let testName = Text(tag: "text", span: nameToken.span, value: nameToken.text)
    TestBlock(tag: "test", span: parser.span, name: testName, body: parser.blockNode)
  of Kind.Use:
    discard parser.advance
    if parser.check(Kind.Ident) and parser.peek.text == "c" and parser.peek(1).kind == Kind.String:
      discard parser.advance
      let header = parser.advance
      discard parser.match(Kind.Dot)
      CImport(tag: "c-import", span: parser.span, header: header.text)
    elif parser.check(Kind.String) and parser.peek(1).kind == Kind.Function:
      let provider = parser.advance
      discard parser.advance
      let functionName = parser.name
      let typeParams = parser.generics()
      var params: seq[Parameter]
      if parser.match(Kind.Paren):
        parser.lines()
        if parser.check(Kind.Close):
          parser.diagnostics.emit(Code.Syntax, functionName.span,
            "Remove empty parentheses from a function with no parameters")
        while not parser.check(Kind.Close) and not parser.check(Kind.Eof):
          params.add(parser.parameter(false))
          parser.lines()
          if not parser.match(Kind.Comma): break
          parser.lines()
        discard parser.expect(Kind.Close, "expected ')'")
      parser.lines()
      var returnType: `Type`
      if parser.check(Kind.Ident) and parser.peek.text == "giving":
        discard parser.advance
        returnType = parser.parseType
      discard parser.match(Kind.Dot)
      let abi = binding(provider.text)
      if abi.isNone:
        parser.diagnostics.emit(Code.Invalid, provider.span,
          "unknown function source '" & provider.text & "'")
      ExternFunction(tag: "extern-function", span: parser.span, public: public,
        abi: if abi.isSome: abi.get else: provider.text, name: functionName,
        typeParams: typeParams, params: params, returnType: returnType)
    else:
      let imported = parser.advance
      let value = imported.text
      var alias: Name
      if parser.check(Kind.Ident) and parser.peek.text == "as":
        discard parser.advance
        alias = parser.name
      discard parser.expect(Kind.Dot, "expected '.'")
      Use(tag: "use", span: parser.span, public: public,
        name: Name(tag: "name", span: imported.span, text: splitFile(value).name),
        path: if imported.kind == Kind.String: value else: "", alias: alias)
  of Kind.Native:
    let nativeToken = parser.advance
    let info = if nativeToken.native.isSome: nativeToken.native.get else: NativeInfo(substrate: "foo")
    if info.header.isSome:
      let headerSource = info.header.get & " {}"
      let headerDiagnostics = newEngine()
      headerDiagnostics.setSource(headerSource, parser.diagnostics.getFile)
      let headerProgram = newParser(newLexer(headerSource, headerDiagnostics).lex(), headerDiagnostics).parse()
      if headerDiagnostics.failed or headerProgram.units[0].body.stmts.len == 0 or headerProgram.units[0].body.stmts[0].tag != "function":
        parser.diagnostics.emit(Code.Syntax, nativeToken.span, "A native function needs a concrete parameter and result signature")
        Broken(tag: "broken", span: nativeToken.span)
      else:
        let declaration = node.Function(headerProgram.units[0].body.stmts[0])
        if declaration.typeParams.len > 0 or declaration.constraints.len > 0:
          parser.diagnostics.emit(Code.Syntax, nativeToken.span, "A native function needs a concrete parameter and result signature")
          Broken(tag: "broken", span: nativeToken.span)
        else:
          ExternFunction(tag: "extern-function", span: nativeToken.span, public: public, abi: "c",
            name: declaration.name, params: declaration.params,
            returnType: if declaration.returnType != nil: declaration.returnType else: Primitive(tag: "primitive", span: nativeToken.span, name: "nothing"),
            native: NativeCode(substrate: info.substrate, code: nativeToken.text))
    else:
      if public: parser.diagnostics.emit(Code.NativePublic, nativeToken.span, "Native blocks cannot be public; export a portable function instead")
      Native(tag: "native", span: nativeToken.span, substrate: info.substrate, code: nativeToken.text)
  of Kind.Type:
    discard parser.advance
    if token.text != "define":
      parser.diagnostics.emit(Code.Syntax, token.span,
        "A named type declaration starts with 'define'")
    let typeName = parser.name
    let typeParams = parser.generics()
    if parser.peek.kind == Kind.Ident and parser.peek.text == "as": discard parser.advance
    else: discard parser.expect(Kind.Is, "expected 'as'")
    var body: Node
    if parser.match(Kind.Packed): body = parser.recordType("packed")
    elif parser.check(Kind.Ident) and parser.peek.text == "c" and parser.peek(1).kind in [Kind.Record, Kind.Union]:
      discard parser.advance
      body = if parser.check(Kind.Union): parser.unionType() else: parser.recordType("c")
    elif parser.check(Kind.Record): body = parser.recordType(if "repr(C)" in attributes: "c" else: "")
    elif parser.check(Kind.Union) and "repr(C)" in attributes: body = parser.unionType()
    elif parser.check(Kind.Choice): body = parser.choiceType()
    elif parser.match(Kind.Opaque): body = Opaque(tag: "opaque", span: token.span)
    else: body = parser.parseType
    var derives: Derive
    if parser.match(Kind.Derives):
      var traits = @[parser.name]
      while parser.match(Kind.Comma): traits.add(parser.name)
      derives = Derive(tag: "derive", span: traits[0].span, traits: traits)
    let constraints = parser.constraints()
    discard parser.expect(Kind.Dot, "expected '.'")
    Alias(tag: "alias", span: parser.span, public: public, name: typeName, typeParams: typeParams,
      body: body, derives: derives, constraints: constraints, attributes: attributes)
  of Kind.When:
    discard parser.advance
    let condition = parser.expression
    let thenBody = parser.blockNode
    while parser.match(Kind.NewlineToken): discard
    var otherwise: Node
    if parser.match(Kind.Otherwise):
      otherwise = if parser.check(Kind.When): parser.statement else: parser.blockNode
    `When`(tag: "when", span: parser.span, cond: condition, `then`: thenBody, `else`: otherwise)
  of Kind.While:
    discard parser.advance
    `While`(tag: "while", span: parser.span, cond: parser.expression, body: parser.blockNode)
  of Kind.For:
    discard parser.advance
    discard parser.expect(Kind.Each, "expected 'each'")
    let binding = parser.name
    discard parser.expect(Kind.In, "expected 'in'")
    `For`(tag: "for", span: parser.span, `bind`: binding, iter: parser.expression, body: parser.blockNode)
  of Kind.Match:
    discard parser.advance
    let value = parser.expression
    discard parser.expect(Kind.Open, "expected '{'")
    var cases: seq[`Case`]
    while not parser.check(Kind.Shut) and not parser.check(Kind.Eof):
      if parser.check(Kind.NewlineToken): discard parser.advance; continue
      discard parser.expect(Kind.Case, "expected 'case'")
      let casePattern = parser.pattern
      var guard: Expression
      if parser.match(Kind.When): guard = parser.expression
      cases.add(`Case`(tag: "case", span: casePattern.span, pattern: casePattern, guard: guard, body: parser.blockNode))
    discard parser.expect(Kind.Shut, "expected '}'")
    Match(tag: "match", span: parser.span, scrutinee: value, cases: cases)
  of Kind.Break:
    discard parser.advance
    discard parser.expect(Kind.Dot, "expected '.'")
    `Break`(tag: "break", span: parser.span)
  of Kind.Continue:
    discard parser.advance
    discard parser.expect(Kind.Dot, "expected '.'")
    `Continue`(tag: "continue", span: parser.span)
  of Kind.After:
    discard parser.advance
    let onError = parser.check(Kind.Ident) and parser.peek.text == "error"
    if onError: discard parser.advance
    `Defer`(tag: "defer", span: parser.span, body: parser.blockNode, error: onError)
  of Kind.Unsafe:
    discard parser.advance
    Unsafe(tag: "unsafe", span: parser.span, body: parser.blockNode)
  of Kind.Eval:
    discard parser.advance
    EvalBlock(tag: "eval", span: parser.span, body: parser.blockNode)
  of Kind.Unreachable:
    discard parser.advance
    discard parser.expect(Kind.Dot, "expected '.'")
    UnreachableStatement(tag: "unreachable-statement", span: parser.span)
  of Kind.Ident, Kind.Sequence, Kind.Text:
    if token.text == "set" and parser.peek(1).kind != Kind.Paren:
      discard parser.advance
      let target = parser.postfix
      discard parser.expect(Kind.To, "expected 'to'")
      let value = parser.expression
      discard parser.expect(Kind.Dot, "expected '.'")
      Assignment(tag: "assignment", span: parser.span, target: target, value: value)
    else: parser.action
  else:
    if public: parser.diagnostics.emit(Code.Syntax, token.span, "public applies to a declaration")
    parser.diagnostics.emit(Code.Syntax, token.span, "unexpected token '" & token.text & "'")
    discard parser.advance
    Broken(tag: "broken", span: token.span)

proc blockNode(parser: Parser): Block =
  parser.mark()
  let opening = parser.expect(Kind.Open, "expected '{'")
  var statements: seq[Statement]
  while not parser.check(Kind.Shut) and not parser.check(Kind.Eof):
    if parser.check(Kind.NewlineToken): discard parser.advance; continue
    statements.add(parser.statement)
  discard parser.expect(Kind.Shut, "expected '}'")
  Block(tag: "block", span: Span(start: opening.span.start,
    `end`: parser.peek(-1).span.`end`, line: opening.span.line,
    col: opening.span.col, file: opening.span.file), stmts: statements)

proc parse*(parser: Parser): Program =
  parser.mark()
  var statements: seq[Statement]
  while not parser.check(Kind.Eof):
    if parser.check(Kind.NewlineToken): discard parser.advance; continue
    statements.add(parser.statement)
  let first = if parser.tokens.len > 0: parser.tokens[0].span else: Span(line: 1, col: 1)
  let file = parser.diagnostics.getFile
  let base = if file.len > 0: splitFile(file).name else: "main"
  let unitName = Name(tag: "name", span: first, text: base)
  let body = Block(tag: "block", span: first, stmts: statements)
  Program(tag: "program", span: first, units: @[Unit(tag: "unit", span: first, name: unitName, file: file, body: body)])
