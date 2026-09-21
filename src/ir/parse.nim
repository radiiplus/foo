import std/[json, strutils, tables]
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

type TextParser = ref object
  values: seq[Token]
  position: int
  registers: Table[string, Value]

proc peek(parser: TextParser): string =
  if parser.position < parser.values.len: parser.values[parser.position].value else: ""
proc take(parser: TextParser; expected = ""): Token =
  if parser.position >= parser.values.len: raise newException(ValueError, "Unexpected end of IR")
  result = parser.values[parser.position]; inc parser.position
  if expected.len > 0 and result.value != expected: raise newException(ValueError, "Expected '" & expected & "', got '" & result.value & "'")
proc accept(parser: TextParser; value: string): bool =
  if parser.peek == value: discard parser.take; true else: false

proc parseType(parser: TextParser): `Type` =
  let value = parser.take.value
  if value == "[":
    let width = parseInt(parser.take.value); discard parser.take("]")
    return `Type`(kind: TypeKind.Array, width: width, elem: parser.parseType)
  if value == "int": return `Type`(kind: TypeKind.Int)
  if value == "uint": return `Type`(kind: TypeKind.Uint)
  if value == "bool": return `Type`(kind: TypeKind.Bool)
  if value == "void": return `Type`(kind: TypeKind.Void)
  if value == "error": return `Type`(kind: TypeKind.Error)
  if value.startsWith("int"): return `Type`(kind: TypeKind.Int, width: parseInt(value[3 .. ^1]))
  if value.startsWith("uint"): return `Type`(kind: TypeKind.Uint, width: parseInt(value[4 .. ^1]))
  if value.startsWith("float"): return `Type`(kind: TypeKind.Float, width: parseInt(value[5 .. ^1]))
  if value in ["slice", "text", "optional", "fallible"]:
    discard parser.take("<")
    let elem = parser.parseType
    discard parser.take(">")
    return `Type`(kind: (if value == "optional": TypeKind.Optional elif value == "fallible": TypeKind.Fallible else: TypeKind.Slice), elem: elem, constant: value == "text")
  if value == "ptr":
    discard parser.take("<")
    let elem = parser.parseType
    discard parser.take(">")
    return `Type`(kind: TypeKind.Ptr, elem: elem)
  `Type`(kind: TypeKind.Struct, name: value)

proc parseValue(parser: TextParser): Value =
  let token = parser.take
  if token.value.startsWith("%"):
    let name = token.value[1 .. ^1]
    if not parser.registers.hasKey(name): parser.registers[name] = Value(kind: ValueKind.Reg, name: name, `type`: `Type`(kind: TypeKind.Void))
    return parser.registers[name]
  if token.value.startsWith("@"):
    return Value(kind: ValueKind.Global, name: token.value[1 .. ^1], `type`: `Type`(kind: TypeKind.Void))
  if token.value in ["true", "false"]: return Value(kind: ValueKind.Const, name: token.value, `type`: `Type`(kind: TypeKind.Bool))
  if token.quoted: return Value(kind: ValueKind.Const, name: "\"" & token.value & "\"", `type`: `Type`(kind: TypeKind.Slice, constant: true, elem: `Type`(kind: TypeKind.Uint, width: 8)))
  if token.value.contains('.'):
    return Value(kind: ValueKind.Const, name: token.value, `type`: `Type`(kind: TypeKind.Float, width: 64))
  Value(kind: ValueKind.Const, name: token.value, `type`: `Type`(kind: TypeKind.Int))

proc isValueStart(parser: TextParser): bool =
  if parser.position >= parser.values.len: return false
  let token = parser.values[parser.position]
  token.quoted or token.value in ["true", "false"] or
    token.value.startsWith("%") or token.value.startsWith("@") or
    (token.value.len > 0 and (token.value[0].isDigit or
      (token.value[0] == '-' and token.value.len > 1 and token.value[1].isDigit)))

proc parseInstruction(parser: TextParser): Instruction

proc parseBlock(parser: TextParser): Block =
  let label = parser.take.value
  discard parser.take(":")
  result = Block(label: label)
  while parser.peek.len > 0 and parser.peek notin ["}", "entry", "then", "else"]:
    let instruction = parser.parseInstruction
    if instruction.kind in {InstrKind.Return, InstrKind.Jump, InstrKind.Cjump, InstrKind.Panic}:
      result.term = instruction
      break
    result.instrs.add(instruction)
  if result.term == nil: raise newException(ValueError, "Block '" & label & "' is missing a terminator")

proc parseInstruction(parser: TextParser): Instruction =
  var dest: Value
  if parser.peek.startsWith("%") and parser.position + 1 < parser.values.len and parser.values[parser.position + 1].value == "=":
    dest = parser.parseValue
    discard parser.take("=")
  let operation = parser.take.value
  case operation
  of "alloc":
    let region = parser.take.value
    let element = parser.parseType
    dest.kind = ValueKind.Reg; dest.`type` = `Type`(kind: TypeKind.Ptr, elem: element)
    Instruction(kind: InstrKind.Alloc, dest: dest, region: region)
  of "load": Instruction(kind: InstrKind.Load, dest: dest, `ptr`: parser.parseValue)
  of "store":
    let value = parser.parseValue; discard parser.take(",")
    Instruction(kind: InstrKind.Store, val: value, `ptr`: parser.parseValue)
  of "add", "sub", "mul", "div", "remainder":
    let left = parser.parseValue; discard parser.take(",")
    let right = parser.parseValue
    let kind = case operation
      of "add": InstrKind.Add
      of "sub": InstrKind.Sub
      of "mul": InstrKind.Mul
      of "div": InstrKind.Div
      else: InstrKind.Remainder
    if dest.name.len > 0:
      dest.type = left.type
      parser.registers[dest.name] = dest
    Instruction(kind: kind, dest: dest, val: left, val2: right)
  of "call":
    let callee = parser.take.value
    var typeArgs: seq[`Type`]
    if parser.accept("["):
      while parser.peek != "]":
        typeArgs.add(parser.parseType)
        if not parser.accept(","): break
      discard parser.take("]")
    discard parser.take("(")
    var args: seq[Value]
    while parser.peek != ")":
      args.add(parser.parseValue)
      if not parser.accept(","): break
    discard parser.take(")")
    if callee.startsWith("%"):
      Instruction(kind: InstrKind.Call, dest: dest, callee: parser.registers.getOrDefault(callee[1 .. ^1]), args: args, typeArgs: typeArgs)
    else:
      Instruction(kind: InstrKind.Call, dest: dest, `func`: callee.strip(chars = {'@'}), args: args, typeArgs: typeArgs)
  of "jump": Instruction(kind: InstrKind.Jump, label: parser.take.value)
  of "cjump":
    let condition = parser.parseValue; discard parser.take(",")
    let yes = parser.take.value; discard parser.take(",")
    Instruction(kind: InstrKind.Cjump, cond: condition, trueLabel: yes, falseLabel: parser.take.value)
  of "return":
    if parser.isValueStart: Instruction(kind: InstrKind.Return, value: parser.parseValue)
    else: Instruction(kind: InstrKind.Return)
  of "panic": Instruction(kind: InstrKind.Panic, msg: parser.take.value)
  of "try": Instruction(kind: InstrKind.Try, dest: dest, expr: parser.parseValue)
  of "eval": Instruction(kind: InstrKind.Eval, dest: dest, evalBody: parser.take.value)
  of "reflect": Instruction(kind: InstrKind.Reflect, dest: dest, typeArg: parser.parseType)
  of "embed": Instruction(kind: InstrKind.Embed, dest: dest, path: parser.take.value)
  of "native":
    discard parser.take("zig")
    Instruction(kind: InstrKind.NativeZig, dest: dest, code: parser.take.value)
  else: raise newException(ValueError, "Unknown instruction: " & operation)

proc parseText(source: string): Module =
  let parser = TextParser(values: tokens(source), registers: initTable[string, Value]())
  discard parser.take("module")
  result = Module(name: parser.take.value, funcs: @[], externs: @[])
  discard parser.take("{")
  while parser.peek != "}":
    if parser.peek == "extern":
      discard parser.take; let abi = parser.take.value; discard parser.take("fn")
      let name = parser.take.value.strip(chars = {'@'}); discard parser.take("(")
      var params: seq[`Type`]
      while parser.peek != ")":
        params.add(parser.parseType)
        if not parser.accept(","): break
      discard parser.take(")"); discard parser.take("->")
      result.externs.add(Extern(name: name, abi: abi, params: params, ret: parser.parseType))
    elif parser.peek == "fn":
      discard parser.take
      let name = parser.take.value.strip(chars = {'@'})
      var typeParams: seq[string]
      if parser.accept("["):
        while parser.peek != "]":
          typeParams.add(parser.take.value)
          if not parser.accept(","): break
        discard parser.take("]")
      discard parser.take("(")
      var params: seq[Value]
      while parser.peek != ")":
        var parameter = Value(kind: ValueKind.Reg, name: parser.take.value.strip(chars = {'%'}))
        discard parser.take(":"); parameter.`type` = parser.parseType
        params.add(parameter); parser.registers[parameter.name] = parameter
        if not parser.accept(","): break
      discard parser.take(")"); discard parser.take("->")
      let function = Function(name: name, typeParams: typeParams, params: params,
        ret: parser.parseType, blocks: @[])
      discard parser.take("{")
      while parser.peek != "}": function.blocks.add(parser.parseBlock)
      discard parser.take("}")
      result.funcs.add(function)
    else: raise newException(ValueError, "Unexpected token: " & parser.peek)
  discard parser.take("}")

proc jsonString(node: JsonNode; key: string; default = ""): string =
  if node.hasKey(key): node[key].getStr else: default
proc jsonInt(node: JsonNode; key: string; default = 0): int =
  if node.hasKey(key): node[key].getInt else: default
proc jsonBool(node: JsonNode; key: string; default = false): bool =
  if node.hasKey(key): node[key].getBool else: default

proc typeFromJson(node: JsonNode; types: Table[string, `Type`]): `Type` =
  if node == nil or node.kind != JObject: raise newException(ValueError, "Malformed IR type")
  let kind = node["kind"].getStr
  let resultKind = case kind
    of "integer": (if node.jsonBool("signed", true): TypeKind.Int else: TypeKind.Uint)
    of "decimal": TypeKind.Float
    of "bool": TypeKind.Bool
    of "pointer": TypeKind.Ptr
    of "array": TypeKind.Array
    of "record": (if node.jsonString("layout") == "c": TypeKind.ExternStruct else: TypeKind.Struct)
    of "unit": TypeKind.Void
    of "error": TypeKind.Error
    of "vector": TypeKind.Vector
    of "choice": TypeKind.TaggedUnion
    of "packed": TypeKind.PackedStruct
    of "union": TypeKind.ExternUnion
    of "opaque": TypeKind.Opaque
    of "function": TypeKind.Function
    of "sequence": TypeKind.Slice
    of "optional": TypeKind.Optional
    of "fallible": TypeKind.Fallible
    of "memory": TypeKind.Memory
    of "region": TypeKind.Region
    of "trace": TypeKind.Trace
    else: raise newException(ValueError, "Unknown type kind '" & kind & "'")
  result = `Type`(kind: resultKind, name: node.jsonString("name"),
    width: node.jsonInt("bits"), abi: node.jsonString("abi"),
    volatile: node.jsonBool("volatile"), constant: node.jsonBool("constant"))
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
    types[id] = typeFromJson(entry["definition"], types)
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
        target.fieldAttrs[field[0].getStr] = attributes
    if definition.hasKey("variants"):
      for variant in definition["variants"]: target.variants[variant["name"].getStr] = if variant["type"].kind == JNull: nil else: types[variant["type"].getStr]
  result = Module(version: 1, stage: data["stage"].getStr, name: data["unit"]["package"].getStr,
    unitPackage: data["unit"]["package"].getStr, unitPath: data["unit"]["path"].getStr,
    requires: data["requires"].getStr, funcs: @[], externs: @[])
  if data.hasKey("target") and data["target"].kind == JObject:
    for key, value in data["target"]:
      result.target[key] = if value.kind == JString: value.getStr else: $value
  if data.hasKey("regions"):
    for entry in data["regions"]:
      result.regions.add(Region(id: entry["id"].getStr, kind: entry["kind"].getStr,
        parent: entry.jsonString("parent"), owner: entry.jsonString("owner")))
  if data.hasKey("traces"):
    for entry in data["traces"]:
      result.traces.add(Trace(id: entry["id"].getStr, `function`: entry["function"].getStr))
  if data.hasKey("native"):
    for entry in data["native"]:
      var effects: seq[string]
      for effect in entry["effects"]: effects.add(effect.getStr)
      result.native.add(NativeContract(id: entry["id"].getStr, stage: entry["stage"].getStr,
        code: entry["code"].getStr, abi: entry["abi"].getStr, effects: effects))
  if data.hasKey("residue"):
    for entry in data["residue"]:
      result.residue.add(Residue(id: entry["id"].getStr, operation: entry["operation"].getStr,
        state: entry["state"].getStr, payload: entry["payload"].getStr))
  for declaration in data["declarations"]:
    result.types.add(TypeDecl(name: declaration["name"].getStr, `type`: types[declaration["type"].getStr]))
  for foreign in data["foreign"]:
    var params: seq[`Type`]
    for parameter in foreign["params"]: params.add(types[parameter.getStr])
    var item = Extern(name: foreign["name"].getStr, symbol: foreign.jsonString("symbol"),
      abi: foreign.jsonString("abi"), params: params, ret: types[foreign["ret"].getStr])
    if foreign.hasKey("typeParams"):
      for parameter in foreign["typeParams"]: item.typeParams.add(parameter.getStr)
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
      let expected = if resolved.width == 32: 8 else: 16
      if resolved.kind != TypeKind.Float or name.len != expected:
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
      if resolved.kind notin {TypeKind.Int, TypeKind.Uint}:
        raise newException(ValueError, "Malformed canonical integer")
    elif encoding in ["text", "bytes"]:
      if resolved.kind != TypeKind.Slice: raise newException(ValueError, "Text data needs a sequence type")
      var raw = if encoding == "bytes": base64.decode(name) else: name
      var values = newSeq[byte](raw.len)
      for index, item in raw: values[index] = byte(item.ord)
      name = quoted(values)
    elif encoding != "literal":
      raise newException(ValueError, "Unknown constant encoding")
    constants[id] = Value(kind: ValueKind.Const, name: name, bits: bits, `type`: resolved)
  proc decodeValue(entry: JsonNode): Value =
    if entry.hasKey("constant"):
      let id = entry["constant"].getStr
      if not constants.hasKey(id): raise newException(ValueError, "Unknown constant '" & id & "'")
      return constants[id]
    if not entry.hasKey("type"): raise newException(ValueError, "Malformed IR value")
    if entry.hasKey("register"):
      return Value(kind: ValueKind.Reg, name: entry["register"].getStr,
        `type`: types[entry["type"].getStr])
    if entry.hasKey("symbol"):
      return Value(kind: ValueKind.Global, name: entry["symbol"].getStr,
        `type`: types[entry["type"].getStr])
    raise newException(ValueError, "IR values need exactly one reference kind")
  proc decodeInstruction(entry: JsonNode): Instruction
  proc decodeBlock(entry: JsonNode): Block =
    result = Block(label: entry["id"].getStr)
    for parameter in entry["parameters"]: result.params.add(decodeValue(parameter))
    for instruction in entry["instructions"]: result.instrs.add(decodeInstruction(instruction))
    result.term = decodeInstruction(entry["terminator"])
  proc decodeInstruction(entry: JsonNode): Instruction =
    let operation = entry["op"].getStr
    var index = -1
    for candidate, name in operations:
      if name == operation: index = candidate
    if index < 0: raise newException(ValueError, "Unknown IR operation '" & operation & "'")
    let attributes = entry["attributes"]
    result = Instruction(kind: InstrKind(index))
    if attributes.hasKey("dest"): result.dest = decodeValue(attributes["dest"])
    if attributes.hasKey("ptr"): result.ptr = decodeValue(attributes["ptr"])
    if attributes.hasKey("val"): result.val = decodeValue(attributes["val"])
    if attributes.hasKey("val2"): result.val2 = decodeValue(attributes["val2"])
    if attributes.hasKey("target"): result.target = decodeValue(attributes["target"])
    if attributes.hasKey("callee"): result.callee = decodeValue(attributes["callee"])
    if attributes.hasKey("cond"): result.cond = decodeValue(attributes["cond"])
    if attributes.hasKey("value"): result.value = decodeValue(attributes["value"])
    if attributes.hasKey("expr"): result.expr = decodeValue(attributes["expr"])
    if attributes.hasKey("args"):
      for argument in attributes["args"]: result.args.add(decodeValue(argument))
    if attributes.hasKey("trueArgs"):
      for argument in attributes["trueArgs"]: result.trueArgs.add(decodeValue(argument))
    if attributes.hasKey("falseArgs"):
      for argument in attributes["falseArgs"]: result.falseArgs.add(decodeValue(argument))
    if attributes.hasKey("blocks"):
      for edge in attributes["blocks"]:
        result.blocks.add((label: edge["label"].getStr, value: decodeValue(edge["value"])))
    if attributes.hasKey("fallback"): result.fallback = decodeBlock(attributes["fallback"])
    if attributes.hasKey("typeArg"): result.typeArg = types[attributes["typeArg"].getStr]
    if attributes.hasKey("typeArgs"):
      for argument in attributes["typeArgs"]: result.typeArgs.add(types[argument.getStr])
    if attributes.hasKey("memory"):
      result.memory = Memory(input: attributes["memory"].jsonString("input"),
        output: attributes["memory"].jsonString("output"))
    if attributes.hasKey("effects"):
      for effect in attributes["effects"]: result.effects.add(effect.getStr)
    if attributes.hasKey("span"):
      result.span = SourceSpan(file: attributes["span"].jsonString("file"),
        start: attributes["span"].jsonInt("start"), `end`: attributes["span"].jsonInt("end"))
    if attributes.hasKey("attributes"):
      for attribute in attributes["attributes"]: result.attributes.add(attribute.getStr)
    result.op = attributes.jsonString("op")
    result.field = attributes.jsonString("field")
    result.panic = attributes.jsonString("panic")
    result.trace = attributes.jsonString("trace")
    result.symbol = attributes.jsonString("symbol")
    result.region = attributes.jsonString("region")
    result.func = attributes.jsonString("func")
    result.abi = attributes.jsonString("abi")
    result.label = attributes.jsonString("label")
    result.trueLabel = attributes.jsonString("trueLabel")
    result.falseLabel = attributes.jsonString("falseLabel")
    result.msg = attributes.jsonString("msg")
    result.handler = attributes.jsonString("handler")
    result.path = attributes.jsonString("path")
    result.evalBody = attributes.jsonString("evalBody")
    result.reduceOp = attributes.jsonString("reduceOp")
    result.code = attributes.jsonString("code")
    result.error = attributes.jsonBool("error")
    if attributes.hasKey("mask"):
      for lane in attributes["mask"]: result.mask.add(lane.getInt)
  for entry in data["functions"]:
    let function = Function(name: entry["name"].getStr,
      public: entry.jsonBool("public"), abi: entry.jsonString("abi"),
      line: entry.jsonInt("line"), ret: types[entry["ret"].getStr])
    if entry.hasKey("typeParams"):
      for parameter in entry["typeParams"]: function.typeParams.add(parameter.getStr)
    if entry.hasKey("attributes"):
      for attribute in entry["attributes"]: function.attributes.add(attribute.getStr)
    if entry.hasKey("derives"):
      for derive in entry["derives"]: function.derives.add(derive.getStr)
    for parameter in entry["params"]: function.params.add(decodeValue(parameter))
    for basicBlock in entry["blocks"]: function.blocks.add(decodeBlock(basicBlock))
    result.funcs.add(function)
  if data.hasKey("storage"):
    for entry in data["storage"]:
      result.storage.add(Storage(name: entry["name"].getStr,
        public: entry.jsonBool("public"), value: decodeValue(entry["value"])))
  let errors = validate(result)
  if errors.len > 0:
    var messages: seq[string]
    for error in errors: messages.add(error.msg)
    raise newException(ValueError, messages.join("\n"))

proc parse*(source: string): Module =
  if source.strip.startsWith("{"): return decode(source)
  parseText(source)
