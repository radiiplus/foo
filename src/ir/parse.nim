import std/[json, sequtils, strutils, tables]
import std/base64 as base64
import ./[kind, node, valid]

type Token = object
  value: string
  quoted: bool

proc tokens(source: string): seq[Token] =
  var index = 0
  while index < source.len:
    while index < source.len and source[index] in {' ', '\t', '\r', '\n'}: inc index
    if index >= source.len: break
    if source[index] == '-' and index + 1 < source.len and source[index + 1] == '-':
      while index < source.len and source[index] != '\n': inc index
      continue
    if source[index] == '-' and index + 1 < source.len and source[index + 1] == '>':
      result.add(Token(value: "->")); index += 2
    elif source[index] == '"':
      inc index
      var value = ""
      while index < source.len and source[index] != '"':
        if source[index] == '\\' and index + 1 < source.len:
          inc index
          value.add(if source[index] == 'n': '\n' else: source[index])
        else: value.add(source[index])
        inc index
      if index < source.len: inc index
      result.add(Token(value: value, quoted: true))
    elif source[index] in {'=', ',', '(', ')', '[', ']', '{', '}', ':', '<', '>'}:
      result.add(Token(value: $source[index])); inc index
    else:
      var value = ""
      while index < source.len and source[index] notin {' ', '\t', '\r', '\n', '=', ',', '(', ')', '[', ']', '{', '}', ':', '<', '>', '"'}:
        value.add(source[index]); inc index
      result.add(Token(value: value))

type Decoder = ref object
  values: seq[Token]
  position: int
  registers: Table[string, Value]

proc peek(parser: Decoder): string =
  if parser.position < parser.values.len: parser.values[parser.position].value else: ""
proc take(parser: Decoder; expected = ""): Token =
  if parser.position >= parser.values.len: raise newException(ValueError, "Unexpected end of IR")
  result = parser.values[parser.position]; inc parser.position
  if expected.len > 0 and result.value != expected: raise newException(ValueError, "Expected '" & expected & "', got '" & result.value & "'")
proc accept(parser: Decoder; value: string): bool =
  if parser.peek == value: discard parser.take; true else: false

proc typed(parser: Decoder): `Type` =
  let value = parser.take.value
  if value == "[":
    let width = parseInt(parser.take.value); discard parser.take("]")
    return `Type`(kind: Shape.Array, width: width, elem: parser.typed)
  if value == "int": return `Type`(kind: Shape.Int)
  if value == "uint": return `Type`(kind: Shape.Uint)
  if value == "bool": return `Type`(kind: Shape.Bool)
  if value == "void": return `Type`(kind: Shape.Void)
  if value == "error": return `Type`(kind: Shape.Error)
  if value.startsWith("int"): return `Type`(kind: Shape.Int, width: parseInt(value[3 .. ^1]))
  if value.startsWith("uint"): return `Type`(kind: Shape.Uint, width: parseInt(value[4 .. ^1]))
  if value.startsWith("float"): return `Type`(kind: Shape.Float, width: parseInt(value[5 .. ^1]))
  if value in ["slice", "text", "optional", "failable"]:
    discard parser.take("<")
    let elem = parser.typed
    discard parser.take(">")
    return `Type`(kind: (if value == "optional": Shape.Optional elif value == "failable": Shape.Failable else: Shape.Slice), elem: elem, constant: value == "text")
  if value == "ptr":
    discard parser.take("<")
    let elem = parser.typed
    discard parser.take(">")
    return `Type`(kind: Shape.Ptr, elem: elem)
  `Type`(kind: Shape.Struct, name: value)

proc value(parser: Decoder): Value =
  let token = parser.take
  if token.value.startsWith("%"):
    let name = token.value[1 .. ^1]
    if not parser.registers.hasKey(name): parser.registers[name] = Value(kind: Flavor.Reg, name: name, `type`: `Type`(kind: Shape.Void))
    return parser.registers[name]
  if token.value.startsWith("@"):
    return Value(kind: Flavor.Global, name: token.value[1 .. ^1], `type`: `Type`(kind: Shape.Void))
  if token.value in ["true", "false"]: return Value(kind: Flavor.Const, name: token.value, `type`: `Type`(kind: Shape.Bool))
  if token.quoted: return Value(kind: Flavor.Const, name: "\"" & token.value & "\"", `type`: `Type`(kind: Shape.Slice, constant: true, elem: `Type`(kind: Shape.Uint, width: 8)))
  if token.value.contains('.'):
    return Value(kind: Flavor.Const, name: token.value, `type`: `Type`(kind: Shape.Float, width: 64))
  Value(kind: Flavor.Const, name: token.value, `type`: `Type`(kind: Shape.Int))

proc starts(parser: Decoder): bool =
  if parser.position >= parser.values.len: return false
  let token = parser.values[parser.position]
  token.quoted or token.value in ["true", "false"] or
    token.value.startsWith("%") or token.value.startsWith("@") or
    (token.value.len > 0 and (token.value[0].isDigit or
      (token.value[0] == '-' and token.value.len > 1 and token.value[1].isDigit)))

proc instruction(parser: Decoder): Instruction

proc body(parser: Decoder): Block =
  let label = parser.take.value
  discard parser.take(":")
  result = Block(label: label)
  while parser.peek.len > 0 and parser.peek notin ["}", "entry", "then", "else"]:
    let instruction = parser.instruction
    if instruction.kind in {Opcode.Return, Opcode.Jump, Opcode.Cjump, Opcode.Panic}:
      result.term = instruction
      break
    result.instrs.add(instruction)
  if result.term == nil: raise newException(ValueError, "Block '" & label & "' is missing a terminator")

proc instruction(parser: Decoder): Instruction =
  var dest: Value
  if parser.peek.startsWith("%") and parser.position + 1 < parser.values.len and parser.values[parser.position + 1].value == "=":
    dest = parser.value
    discard parser.take("=")
  let operation = parser.take.value
  case operation
  of "alloc":
    let region = parser.take.value
    let element = parser.typed
    dest.kind = Flavor.Reg; dest.`type` = `Type`(kind: Shape.Ptr, elem: element)
    Instruction(kind: Opcode.Alloc, dest: dest, region: region)
  of "load": Instruction(kind: Opcode.Load, dest: dest, `ptr`: parser.value)
  of "store":
    let value = parser.value; discard parser.take(",")
    Instruction(kind: Opcode.Store, val: value, `ptr`: parser.value)
  of "bit":
    let mode = parser.take.value
    let left = parser.value
    var right: Value
    if mode != "not":
      discard parser.take(",")
      right = parser.value
    if dest.name.len > 0:
      dest.type = left.type
      parser.registers[dest.name] = dest
    Instruction(kind: Opcode.Bit, op: mode, dest: dest, val: left, val2: right)
  of "add", "sub", "mul", "div", "remainder":
    let left = parser.value; discard parser.take(",")
    let right = parser.value
    let kind = case operation
      of "add": Opcode.Add
      of "sub": Opcode.Sub
      of "mul": Opcode.Mul
      of "div": Opcode.Div
      else: Opcode.Remainder
    if dest.name.len > 0:
      dest.type = left.type
      parser.registers[dest.name] = dest
    Instruction(kind: kind, dest: dest, val: left, val2: right)
  of "call":
    let callee = parser.take.value
    var arguments: seq[`Type`]
    if parser.accept("["):
      while parser.peek != "]":
        arguments.add(parser.typed)
        if not parser.accept(","): break
      discard parser.take("]")
    discard parser.take("(")
    var args: seq[Value]
    while parser.peek != ")":
      args.add(parser.value)
      if not parser.accept(","): break
    discard parser.take(")")
    if callee.startsWith("%"):
      Instruction(kind: Opcode.Call, dest: dest, callee: parser.registers.getOrDefault(callee[1 .. ^1]), args: args, arguments: arguments)
    else:
      Instruction(kind: Opcode.Call, dest: dest, `func`: callee.strip(chars = {'@'}), args: args, arguments: arguments)
  of "jump": Instruction(kind: Opcode.Jump, label: parser.take.value)
  of "cjump":
    let condition = parser.value; discard parser.take(",")
    let yes = parser.take.value; discard parser.take(",")
    Instruction(kind: Opcode.Cjump, cond: condition, yes: yes, no: parser.take.value)
  of "return":
    if parser.starts: Instruction(kind: Opcode.Return, value: parser.value)
    else: Instruction(kind: Opcode.Return)
  of "panic": Instruction(kind: Opcode.Panic, msg: parser.take.value)
  of "try": Instruction(kind: Opcode.Try, dest: dest, expr: parser.value)
  of "eval": Instruction(kind: Opcode.Eval, dest: dest, evaluation: parser.take.value)
  of "reflect": Instruction(kind: Opcode.Reflect, dest: dest, argument: parser.typed)
  of "embed": Instruction(kind: Opcode.Embed, dest: dest, path: parser.take.value)
  else: raise newException(ValueError, "Unknown instruction: " & operation)

proc text(source: string): Module =
  let parser = Decoder(values: tokens(source), registers: initTable[string, Value]())
  discard parser.take("module")
  result = Module(name: parser.take.value, funcs: @[], externs: @[])
  discard parser.take("{")
  while parser.peek != "}":
    if parser.peek == "extern":
      discard parser.take; let abi = parser.take.value; discard parser.take("fn")
      let name = parser.take.value.strip(chars = {'@'}); discard parser.take("(")
      var params: seq[`Type`]
      while parser.peek != ")":
        params.add(parser.typed)
        if not parser.accept(","): break
      discard parser.take(")"); discard parser.take("->")
      result.externs.add(Extern(name: name, abi: abi, params: params, ret: parser.typed))
    elif parser.peek == "fn":
      discard parser.take
      let name = parser.take.value.strip(chars = {'@'})
      var generics: seq[string]
      if parser.accept("["):
        while parser.peek != "]":
          generics.add(parser.take.value)
          if not parser.accept(","): break
        discard parser.take("]")
      discard parser.take("(")
      var params: seq[Value]
      while parser.peek != ")":
        var parameter = Value(kind: Flavor.Reg, name: parser.take.value.strip(chars = {'%'}))
        discard parser.take(":"); parameter.`type` = parser.typed
        params.add(parameter); parser.registers[parameter.name] = parameter
        if not parser.accept(","): break
      discard parser.take(")"); discard parser.take("->")
      let function = Function(name: name, generics: generics, params: params,
        ret: parser.typed, blocks: @[])
      discard parser.take("{")
      while parser.peek != "}": function.blocks.add(parser.body)
      discard parser.take("}")
      result.funcs.add(function)
    else: raise newException(ValueError, "Unexpected token: " & parser.peek)
  discard parser.take("}")

proc text(node: JsonNode; key: string; default = ""): string =
  if node.hasKey(key): node[key].getStr else: default
proc integer(node: JsonNode; key: string; default = 0): int =
  if node.hasKey(key): node[key].getInt else: default
proc boolean(node: JsonNode; key: string; default = false): bool =
  if node.hasKey(key): node[key].getBool else: default

proc typed(node: JsonNode; types: Table[string, `Type`]): `Type` =
  if node == nil or node.kind != JObject: raise newException(ValueError, "Malformed IR type")
  let kind = node["kind"].getStr
  let returned = case kind
    of "integer": (if node.boolean("signed", true): Shape.Int else: Shape.Uint)
    of "decimal": Shape.Float
    of "bool": Shape.Bool
    of "pointer": Shape.Ptr
    of "array": Shape.Array
    of "record": (if node.text("layout") == "c": Shape.ExternStruct else: Shape.Struct)
    of "unit": Shape.Void
    of "error": Shape.Error
    of "vector": Shape.Vector
    of "choice": Shape.TaggedUnion
    of "packed": Shape.PackedStruct
    of "union": Shape.ExternUnion
    of "opaque": Shape.Opaque
    of "function": Shape.Function
    of "sequence": Shape.Slice
    of "optional": Shape.Optional
    of "failable": Shape.Failable
    of "memory": Shape.Memory
    of "region": Shape.Region
    of "trace": Shape.Trace
    else: raise newException(ValueError, "Unknown type kind '" & kind & "'")
  result = `Type`(kind: returned, name: node.text("name"),
    width: (if returned in {Shape.Array, Shape.Vector}:
      node.integer("width") else: node.integer("bits")),
    abi: node.text("abi"),
    volatile: node.boolean("volatile"), constant: node.boolean("constant"))
  if node.hasKey("attributes"):
    for attribute in node["attributes"]: result.attributes.add(attribute.getStr)

proc decode*(source: string): Module =
  let data = parseJson(source)
  if data["format"].getStr != "foo.ir" or data["version"].getInt != 1:
    raise newException(ValueError, "Unsupported FOO IR format or version")
  if data["stage"].getStr notin ["@foo", "@c", "@asm"]:
    raise newException(ValueError, "Unsupported FOO IR stage")
  var types = initTable[string, `Type`]()
  for entry in data["types"]:
    let id = entry["id"].getStr
    if types.hasKey(id): raise newException(ValueError, "Duplicate type '" & id & "'")
    types[id] = typed(entry["definition"], types)
  for entry in data["types"]:
    let target = types[entry["id"].getStr]
    let definition = entry["definition"]
    if definition.hasKey("element"): target.elem = types[definition["element"].getStr]
    if definition.hasKey("result"): target.ret = types[definition["result"].getStr]
    if definition.hasKey("parameters"):
      for parameter in definition["parameters"]: target.params.add(types[parameter.getStr])
    if definition.hasKey("fields"):
      for field in definition["fields"]: target.fields[field["name"].getStr] = types[field["type"].getStr]
    if definition.hasKey("fieldAttrs"):
      for field in definition["fieldAttrs"]:
        var attributes: seq[string]
        for attribute in field[1]: attributes.add(attribute.getStr)
        target.annotations[field[0].getStr] = attributes
    if definition.hasKey("variants"):
      for variant in definition["variants"]: target.variants[variant["name"].getStr] = if variant["type"].kind == JNull: nil else: types[variant["type"].getStr]
  result = Module(version: 1, stage: data["stage"].getStr, name: data["unit"]["package"].getStr,
    package: data["unit"]["package"].getStr, path: data["unit"]["path"].getStr,
    requires: data["requires"].getStr, funcs: @[], externs: @[])
  if data.hasKey("target") and data["target"].kind == JObject:
    for key, value in data["target"]:
      result.target[key] = if value.kind == JString: value.getStr else: $value
  if data.hasKey("regions"):
    for entry in data["regions"]:
      result.regions.add(Region(id: entry["id"].getStr, kind: entry["kind"].getStr,
        parent: entry.text("parent"), owner: entry.text("owner")))
  if data.hasKey("traces"):
    for entry in data["traces"]:
      result.traces.add(Trace(id: entry["id"].getStr, `function`: entry["function"].getStr))
  if data.hasKey("native"):
    for entry in data["native"]:
      var effects: seq[string]
      for effect in entry["effects"]: effects.add(effect.getStr)
      result.native.add(Contract(id: entry["id"].getStr, stage: entry["stage"].getStr,
        code: entry["code"].getStr, abi: entry["abi"].getStr, effects: effects))
  if data.hasKey("residue"):
    for entry in data["residue"]:
      result.residue.add(Residue(id: entry["id"].getStr, operation: entry["operation"].getStr,
        state: entry["state"].getStr, payload: entry["payload"].getStr))
  for declaration in data["declarations"]:
    result.types.add(Definition(name: declaration["name"].getStr, `type`: types[declaration["type"].getStr]))
  for foreign in data["foreign"]:
    var params: seq[`Type`]
    for parameter in foreign["params"]: params.add(types[parameter.getStr])
    var item = Extern(name: foreign["name"].getStr, symbol: foreign.text("symbol"),
      abi: foreign.text("abi"), params: params, ret: types[foreign["ret"].getStr])
    if foreign.hasKey("typeParams"):
      for parameter in foreign["typeParams"]: item.generics.add(parameter.getStr)
    result.externs.add(item)
  var constants = initTable[string, Value]()
  for entry in data["constants"]:
    let id = entry["id"].getStr
    if constants.hasKey(id): raise newException(ValueError, "Duplicate constant '" & id & "'")
    let resolved = types[entry["type"].getStr]
    let encoding = entry["encoding"].getStr
    var name = entry["value"].getStr
    var bits = ""
    if encoding == "bits":
      bits = name
      if resolved.kind != Shape.Float:
        if resolved.kind notin {Shape.Array, Shape.Vector, Shape.Struct,
            Shape.ExternStruct, Shape.TaggedUnion, Shape.ExternUnion,
            Shape.PackedStruct} or name.len == 0 or name.len mod 2 != 0 or
            name.anyIt(it notin {'0'..'9', 'a'..'f'}):
          raise newException(ValueError, "Malformed aggregate bit pattern")
        name = ""
      else:
        let expected = if resolved.width == 32: 8 else: 16
        if name.len != expected:
          raise newException(ValueError, "Malformed floating bit pattern")
        var raw: uint64
        for digit in name:
          raw = raw shl 4
          if digit in {'0'..'9'}: raw = raw or uint64(ord(digit) - ord('0'))
          elif digit in {'a'..'f'}: raw = raw or uint64(ord(digit) - ord('a') + 10)
          else: raise newException(ValueError, "Malformed floating bit pattern")
        if resolved.width == 32:
          var raw32 = uint32(raw)
          var number: float32
          copyMem(number.addr, raw32.addr, sizeof(raw32))
          name = if raw32 == 0x80000000'u32: "-0.0" else: $number
        else:
          var number: float64
          copyMem(number.addr, raw.addr, sizeof(raw))
          name = if raw == 0x8000000000000000'u64: "-0.0" else: $number
    elif encoding == "integer":
      if resolved.kind notin {Shape.Int, Shape.Uint}:
        raise newException(ValueError, "Malformed canonical integer")
    elif encoding in ["text", "bytes"]:
      if resolved.kind != Shape.Slice: raise newException(ValueError, "Text data needs a sequence type")
      var raw = if encoding == "bytes": base64.decode(name) else: name
      var values = newSeq[byte](raw.len)
      for index, item in raw: values[index] = byte(item.ord)
      name = quoted(values)
    elif encoding != "literal":
      raise newException(ValueError, "Unknown constant encoding")
    constants[id] = Value(kind: Flavor.Const, name: name, bits: bits, `type`: resolved)
  proc value(entry: JsonNode): Value =
    if entry.hasKey("constant"):
      let id = entry["constant"].getStr
      if not constants.hasKey(id): raise newException(ValueError, "Unknown constant '" & id & "'")
      return constants[id]
    if not entry.hasKey("type"): raise newException(ValueError, "Malformed IR value")
    if entry.hasKey("register"):
      return Value(kind: Flavor.Reg, name: entry["register"].getStr,
        `type`: types[entry["type"].getStr])
    if entry.hasKey("symbol"):
      return Value(kind: Flavor.Global, name: entry["symbol"].getStr,
        `type`: types[entry["type"].getStr])
    raise newException(ValueError, "IR values need exactly one reference kind")
  proc instruction(entry: JsonNode): Instruction
  proc body(entry: JsonNode): Block =
    result = Block(label: entry["id"].getStr)
    for parameter in entry["parameters"]: result.params.add(value(parameter))
    for instruction in entry["instructions"]: result.instrs.add(instruction(instruction))
    result.term = instruction(entry["terminator"])
  proc instruction(entry: JsonNode): Instruction =
    let operation = entry["op"].getStr
    var index = -1
    for candidate, name in operations:
      if name == operation: index = candidate
    if index < 0: raise newException(ValueError, "Unknown IR operation '" & operation & "'")
    let attributes = entry["attributes"]
    result = Instruction(kind: Opcode(index))
    if attributes.hasKey("dest"): result.dest = value(attributes["dest"])
    if attributes.hasKey("ptr"): result.ptr = value(attributes["ptr"])
    if attributes.hasKey("val"): result.val = value(attributes["val"])
    if attributes.hasKey("val2"): result.val2 = value(attributes["val2"])
    if attributes.hasKey("target"): result.target = value(attributes["target"])
    if attributes.hasKey("callee"): result.callee = value(attributes["callee"])
    if attributes.hasKey("cond"): result.cond = value(attributes["cond"])
    if attributes.hasKey("value"): result.value = value(attributes["value"])
    if attributes.hasKey("expr"): result.expr = value(attributes["expr"])
    if attributes.hasKey("args"):
      for argument in attributes["args"]: result.args.add(value(argument))
    if attributes.hasKey("trueArgs"):
      for argument in attributes["trueArgs"]: result.positive.add(value(argument))
    if attributes.hasKey("falseArgs"):
      for argument in attributes["falseArgs"]: result.negative.add(value(argument))
    if attributes.hasKey("blocks"):
      for edge in attributes["blocks"]:
        result.blocks.add((label: edge["label"].getStr, value: value(edge["value"])))
    if attributes.hasKey("fallback"): result.fallback = body(attributes["fallback"])
    if attributes.hasKey("fallbackBlocks"):
      for section in attributes["fallbackBlocks"]:
        result.fallbackBlocks.add(body(section))
    if attributes.hasKey("typeArg"): result.argument = types[attributes["typeArg"].getStr]
    if attributes.hasKey("typeArgs"):
      for argument in attributes["typeArgs"]: result.arguments.add(types[argument.getStr])
    if attributes.hasKey("memory"):
      result.memory = Memory(input: attributes["memory"].text("input"),
        output: attributes["memory"].text("output"))
    if attributes.hasKey("effects"):
      for effect in attributes["effects"]: result.effects.add(effect.getStr)
    if attributes.hasKey("span"):
      result.span = Location(file: attributes["span"].text("file"),
        start: attributes["span"].integer("start"), `end`: attributes["span"].integer("end"))
    if attributes.hasKey("attributes"):
      for attribute in attributes["attributes"]: result.attributes.add(attribute.getStr)
    result.op = attributes.text("op")
    result.field = attributes.text("field")
    result.panic = attributes.text("panic")
    result.trace = attributes.text("trace")
    result.symbol = attributes.text("symbol")
    result.region = attributes.text("region")
    result.func = attributes.text("func")
    result.abi = attributes.text("abi")
    result.label = attributes.text("label")
    result.yes = attributes.text("trueLabel")
    result.no = attributes.text("falseLabel")
    result.msg = attributes.text("msg")
    result.handler = attributes.text("handler")
    result.path = attributes.text("path")
    result.evaluation = attributes.text("evalBody")
    result.reduction = attributes.text("reduceOp")
    result.code = attributes.text("code")
    result.error = attributes.boolean("error")
    if attributes.hasKey("mask"):
      for lane in attributes["mask"]: result.mask.add(lane.getInt)
  for entry in data["functions"]:
    let function = Function(name: entry["name"].getStr,
      public: entry.boolean("public"), abi: entry.text("abi"),
      line: entry.integer("line"), ret: types[entry["ret"].getStr])
    if entry.hasKey("typeParams"):
      for parameter in entry["typeParams"]: function.generics.add(parameter.getStr)
    if entry.hasKey("attributes"):
      for attribute in entry["attributes"]: function.attributes.add(attribute.getStr)
    if entry.hasKey("derives"):
      for derive in entry["derives"]: function.derives.add(derive.getStr)
    for parameter in entry["params"]: function.params.add(value(parameter))
    for section in entry["blocks"]: function.blocks.add(body(section))
    result.funcs.add(function)
  if data.hasKey("storage"):
    for entry in data["storage"]:
      result.storage.add(Storage(name: entry["name"].getStr,
        public: entry.boolean("public"), thread: entry.boolean("thread"),
        alignment: (if entry.hasKey("alignment"):
          entry["alignment"].getInt() else: 0),
        section: entry.text("section"),
        value: value(entry["value"])))
  let errors = validate(result)
  if errors.len > 0:
    var messages: seq[string]
    for error in errors: messages.add(error.msg)
    raise newException(ValueError, messages.join("\n"))

proc parse*(source: string): Module =
  if source.strip.startsWith("{"): return decode(source)
  text(source)
