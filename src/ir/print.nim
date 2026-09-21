import std/[algorithm, base64, json, strutils, tables, unicode]
import ./[kind, node]

proc encode*(module: Module): string

proc typeStr(value: `Type`): string =
  if value == nil: return "void"
  case value.kind
  of TypeKind.Int: (if value.width > 0: "int" & $value.width else: "int")
  of TypeKind.Uint: (if value.width > 0: "uint" & $value.width else: "uint")
  of TypeKind.Float: (if value.width > 0: "float" & $value.width else: "float")
  of TypeKind.Bool: "bool"
  of TypeKind.Ptr: "ptr<" & typeStr(value.elem) & ">"
  of TypeKind.Slice: (if value.constant: "text<" else: "slice<") & typeStr(value.elem) & ">"
  of TypeKind.Optional: "optional<" & typeStr(value.elem) & ">"
  of TypeKind.Fallible: "fallible<" & typeStr(value.elem) & ">"
  of TypeKind.Array: "[" & $value.width & "]" & typeStr(value.elem)
  of TypeKind.Struct: (if value.name.len > 0: value.name else: "struct")
  of TypeKind.Void: "void"
  of TypeKind.Error: "error"
  of TypeKind.Vector: "vec<" & $value.width & "," & typeStr(value.elem) & ">"
  of TypeKind.TaggedUnion: (if value.name.len > 0: value.name else: "choice")
  of TypeKind.PackedStruct: (if value.name.len > 0: value.name else: "packed")
  of TypeKind.ExternUnion: (if value.name.len > 0: value.name else: "c_union")
  of TypeKind.ExternStruct: (if value.name.len > 0: value.name else: "c_record")
  of TypeKind.Opaque: (if value.name.len > 0: value.name else: "opaque")
  of TypeKind.Function:
    var params: seq[string]
    for parameter in value.params: params.add(typeStr(parameter))
    "fn<" & params.join(",") & "," & typeStr(value.ret) & ">"
  of TypeKind.Memory: "memory"
  of TypeKind.Region: "region"
  of TypeKind.Trace: "trace"

proc valueStr(value: Value): string =
  case value.kind
  of ValueKind.Reg: "%" & value.name
  of ValueKind.Const: value.name
  of ValueKind.Global: "@" & value.name

proc printInstr(instruction: Instruction): string =
  if instruction == nil: return ""
  let dest = if instruction.dest.name.len > 0: valueStr(instruction.dest) & " = " else: ""
  case instruction.kind
  of InstrKind.Alloc: dest & "alloc " & instruction.region & " " & typeStr(instruction.dest.type.elem)
  of InstrKind.Load: dest & "load " & valueStr(instruction.ptr)
  of InstrKind.Store: "store " & valueStr(instruction.val) & ", " & valueStr(instruction.ptr)
  of InstrKind.Add: dest & "add " & valueStr(instruction.val) & ", " & valueStr(instruction.val2)
  of InstrKind.Sub: dest & "sub " & valueStr(instruction.val) & ", " & valueStr(instruction.val2)
  of InstrKind.Mul: dest & "mul " & valueStr(instruction.val) & ", " & valueStr(instruction.val2)
  of InstrKind.Div: dest & "div " & valueStr(instruction.val) & ", " & valueStr(instruction.val2)
  of InstrKind.Remainder: dest & "remainder " & valueStr(instruction.val) & ", " & valueStr(instruction.val2)
  of InstrKind.Call:
    var args: seq[string]
    for argument in instruction.args: args.add(valueStr(argument))
    var typeArgs = ""
    if instruction.typeArgs.len > 0:
      var values: seq[string]
      for typ in instruction.typeArgs: values.add(typeStr(typ))
      typeArgs = "[" & values.join(", ") & "]"
    let callee = if instruction.callee.name.len > 0: valueStr(instruction.callee) else: "@" & instruction.func
    dest & "call " & callee & typeArgs & "(" & args.join(", ") & ")"
  of InstrKind.Jump: "jump " & instruction.label
  of InstrKind.Cjump: "cjump " & valueStr(instruction.cond) & ", " & instruction.trueLabel & ", " & instruction.falseLabel
  of InstrKind.Return: (if instruction.value.name.len > 0: "return " & valueStr(instruction.value) else: "return")
  of InstrKind.Panic: "panic \"" & instruction.msg & "\""
  of InstrKind.Try: dest & "try " & valueStr(instruction.expr) & (if instruction.handler.len > 0: ", " & instruction.handler else: "")
  of InstrKind.Catch, InstrKind.Defer:
    let body = instruction.fallback
    var lines: seq[string]
    if body != nil:
      for child in body.instrs: lines.add("  " & printInstr(child))
      if body.term != nil: lines.add("  " & printInstr(body.term))
    dest & (if instruction.kind == InstrKind.Catch: "catch " & valueStr(instruction.val) else: "defer" & (if instruction.error: " error" else: "")) &
      " {\n" & (if body != nil: body.label else: "") & ":\n" & lines.join("\n") & "\n}"
  of InstrKind.Phi:
    var sources: seq[string]
    for source in instruction.blocks: sources.add("[" & source.label & ": " & valueStr(source.value) & "]")
    dest & "phi " & sources.join(", ")
  of InstrKind.Eval: dest & "eval \"" & instruction.evalBody & "\""
  of InstrKind.Reflect: dest & "reflect " & typeStr(instruction.typeArg)
  of InstrKind.Embed: dest & "embed \"" & instruction.path & "\""
  of InstrKind.Splat: dest & "splat " & valueStr(instruction.val)
  of InstrKind.Shuffle:
    var mask: seq[string]
    for lane in instruction.mask: mask.add($lane)
    dest & "shuffle " & valueStr(instruction.val) & ", " & valueStr(instruction.val2) & ", " & mask.join(", ")
  of InstrKind.Select: dest & "select " & valueStr(instruction.cond) & ", " & valueStr(instruction.val) & ", " & valueStr(instruction.val2)
  of InstrKind.Reduce: dest & "reduce " & instruction.reduceOp.toLowerAscii & ", " & valueStr(instruction.val)
  of InstrKind.NativeZig: dest & "native zig " & $(%instruction.code)
  else: dest & operations[instruction.kind.ord]

proc print*(module: Module): string =
  if module.version == 1: return encode(module)
  var output = "module " & module.name & " {\n\n"
  for foreign in module.externs:
    var params: seq[string]
    for parameter in foreign.params: params.add(typeStr(parameter))
    output.add("  extern \"" & foreign.abi & "\" fn @" & foreign.name & "(" & params.join(", ") & ") -> " & typeStr(foreign.ret) & "\n")
  if module.externs.len > 0: output.add("\n")
  for function in module.funcs:
    var params: seq[string]
    for parameter in function.params: params.add(valueStr(parameter) & ": " & typeStr(parameter.type))
    let typeParams = if function.typeParams.len > 0: "[" & function.typeParams.join(", ") & "]" else: ""
    output.add("fn @" & function.name & typeParams & "(" & params.join(", ") & ") -> " & typeStr(function.ret) & " {\n")
    for basicBlock in function.blocks:
      output.add("\n" & basicBlock.label & ":\n")
      for instruction in basicBlock.instrs: output.add("  " & printInstr(instruction) & "\n")
      output.add("  " & printInstr(basicBlock.term) & "\n")
    output.add("}\n\n")
  output.strip & "\n}"

proc encode*(module: Module): string =
  var definitions = newJArray()
  var known = initTable[pointer, string]()
  proc encodeType(value: `Type`): string =
    if value == nil: return ""
    let identity = cast[pointer](value)
    if known.hasKey(identity): return known[identity]
    let id = "t" & $known.len
    known[identity] = id
    let index = definitions.len
    definitions.add(newJNull())
    let names = ["integer", "decimal", "bool", "pointer", "array", "record",
      "unit", "error", "vector", "choice", "packed", "union", "opaque",
      "function", "integer", "record", "sequence", "optional", "fallible",
      "memory", "region", "trace"]
    var definition = newJObject()
    definition["kind"] = %names[value.kind.ord]
    if value.name.len > 0: definition["name"] = %value.name
    if value.kind in {TypeKind.Int, TypeKind.Uint, TypeKind.Float}:
      definition["bits"] = %(if value.width > 0: value.width elif value.kind == TypeKind.Float: 64 else: 32)
    if value.kind in {TypeKind.Int, TypeKind.Uint}: definition["signed"] = %(value.kind == TypeKind.Int)
    if value.kind == TypeKind.ExternStruct: definition["layout"] = %"c"
    if value.abi.len > 0: definition["abi"] = %value.abi
    if value.attributes.len > 0: definition["attributes"] = %value.attributes
    if value.volatile: definition["volatile"] = %true
    if value.constant: definition["constant"] = %true
    if value.elem != nil: definition["element"] = %encodeType(value.elem)
    if value.params.len > 0:
      definition["parameters"] = newJArray()
      for parameter in value.params: definition["parameters"].add(%encodeType(parameter))
    if value.ret != nil: definition["result"] = %encodeType(value.ret)
    if value.fields.len > 0:
      definition["fields"] = newJArray()
      var names: seq[string]
      for name in value.fields.keys: names.add(name)
      names.sort()
      for name in names: definition["fields"].add(%* {"name": name, "type": encodeType(value.fields[name])})
    if value.fieldAttrs.len > 0:
      definition["fieldAttrs"] = newJArray()
      var names: seq[string]
      for name in value.fieldAttrs.keys: names.add(name)
      names.sort()
      for name in names: definition["fieldAttrs"].add(%* [name, value.fieldAttrs[name]])
    if value.variants.len > 0:
      definition["variants"] = newJArray()
      var names: seq[string]
      for name in value.variants.keys: names.add(name)
      names.sort()
      for name in names:
        definition["variants"].add(%* {"name": name,
          "type": (if value.variants[name] == nil: newJNull() else: %encodeType(value.variants[name]))})
    definitions.elems[index] = %* {"id": id, "definition": definition}
    id
  var constants = newJArray()
  var interned = initTable[string, string]()
  proc encodeValue(value: Value): JsonNode =
    let reference = encodeType(value.type)
    if value.kind == ValueKind.Const:
      var encoding = "literal"
      var data = value.name
      if value.name != "undefined" and value.type != nil and value.type.kind in {TypeKind.Int, TypeKind.Uint}:
        encoding = "integer"
        data = value.name.replace("_", "")
      elif value.name != "undefined" and value.type != nil and value.type.kind == TypeKind.Float:
        encoding = "bits"
        if value.bits.len > 0: data = value.bits
        elif value.type.width == 32:
          var number = parseFloat(value.name).float32
          var raw: uint32
          copyMem(raw.addr, number.addr, sizeof(raw))
          data = toHex(raw, 8).toLowerAscii
        else:
          var number = parseFloat(value.name)
          var raw: uint64
          copyMem(raw.addr, number.addr, sizeof(raw))
          data = toHex(raw, 16).toLowerAscii
      elif value.name != "undefined" and value.type != nil and value.type.kind == TypeKind.Slice:
        let raw = bytes(value.name)
        var text = newString(raw.len)
        for index, item in raw: text[index] = char(item)
        if text.validateUtf8 == -1:
          encoding = "text"
          data = text
        else:
          encoding = "bytes"
          data = encode(raw)
      let key = reference & "\0" & encoding & "\0" & data
      if not interned.hasKey(key):
        let id = "c" & $interned.len
        interned[key] = id
        constants.add(%* {"id": id, "type": reference, "encoding": encoding, "value": data})
      return %* {"constant": interned[key]}
    if value.kind == ValueKind.Reg: %* {"register": value.name, "type": reference}
    else: %* {"symbol": value.name, "type": reference}
  proc encodeInstruction(instruction: Instruction): JsonNode
  proc encodeBlock(basicBlock: Block): JsonNode
  proc encodeInstruction(instruction: Instruction): JsonNode =
    var attributes = newJObject()
    if instruction == nil: return %* {"op": "", "attributes": attributes}
    if instruction.dest.name.len > 0: attributes["dest"] = encodeValue(instruction.dest)
    if instruction.ptr.name.len > 0: attributes["ptr"] = encodeValue(instruction.ptr)
    if instruction.target.name.len > 0: attributes["target"] = encodeValue(instruction.target)
    if instruction.callee.name.len > 0: attributes["callee"] = encodeValue(instruction.callee)
    if instruction.val.name.len > 0: attributes["val"] = encodeValue(instruction.val)
    if instruction.val2.name.len > 0: attributes["val2"] = encodeValue(instruction.val2)
    if instruction.value.name.len > 0: attributes["value"] = encodeValue(instruction.value)
    if instruction.cond.name.len > 0: attributes["cond"] = encodeValue(instruction.cond)
    if instruction.expr.name.len > 0: attributes["expr"] = encodeValue(instruction.expr)
    if instruction.memory.input.len > 0 or instruction.memory.output.len > 0:
      attributes["memory"] = newJObject()
      if instruction.memory.input.len > 0: attributes["memory"]["input"] = %instruction.memory.input
      if instruction.memory.output.len > 0: attributes["memory"]["output"] = %instruction.memory.output
    if instruction.trueArgs.len > 0:
      attributes["trueArgs"] = newJArray()
      for argument in instruction.trueArgs: attributes["trueArgs"].add(encodeValue(argument))
    if instruction.falseArgs.len > 0:
      attributes["falseArgs"] = newJArray()
      for argument in instruction.falseArgs: attributes["falseArgs"].add(encodeValue(argument))
    if instruction.op.len > 0: attributes["op"] = %instruction.op
    if instruction.field.len > 0: attributes["field"] = %instruction.field
    if instruction.panic.len > 0: attributes["panic"] = %instruction.panic
    if instruction.trace.len > 0: attributes["trace"] = %instruction.trace
    if instruction.effects.len > 0: attributes["effects"] = %instruction.effects
    if instruction.span.file.len > 0 or instruction.span.start != 0 or instruction.span.`end` != 0:
      attributes["span"] = %* {"file": instruction.span.file, "start": instruction.span.start, "end": instruction.span.`end`}
    if instruction.error: attributes["error"] = %true
    if instruction.fallback != nil: attributes["fallback"] = encodeBlock(instruction.fallback)
    if instruction.symbol.len > 0: attributes["symbol"] = %instruction.symbol
    if instruction.region.len > 0: attributes["region"] = %instruction.region
    if instruction.func.len > 0: attributes["func"] = %instruction.func
    if instruction.abi.len > 0: attributes["abi"] = %instruction.abi
    if instruction.attributes.len > 0: attributes["attributes"] = %instruction.attributes
    if instruction.label.len > 0: attributes["label"] = %instruction.label
    if instruction.trueLabel.len > 0: attributes["trueLabel"] = %instruction.trueLabel
    if instruction.falseLabel.len > 0: attributes["falseLabel"] = %instruction.falseLabel
    if instruction.msg.len > 0: attributes["msg"] = %instruction.msg
    if instruction.handler.len > 0: attributes["handler"] = %instruction.handler
    if instruction.path.len > 0: attributes["path"] = %instruction.path
    if instruction.evalBody.len > 0: attributes["evalBody"] = %instruction.evalBody
    if instruction.reduceOp.len > 0: attributes["reduceOp"] = %instruction.reduceOp
    if instruction.code.len > 0: attributes["code"] = %instruction.code
    if instruction.args.len > 0:
      attributes["args"] = newJArray()
      for argument in instruction.args: attributes["args"].add(encodeValue(argument))
    if instruction.blocks.len > 0:
      attributes["blocks"] = newJArray()
      for edge in instruction.blocks:
        attributes["blocks"].add(%* {"label": edge.label, "value": encodeValue(edge.value)})
    if instruction.typeArg != nil: attributes["typeArg"] = %encodeType(instruction.typeArg)
    if instruction.typeArgs.len > 0:
      attributes["typeArgs"] = newJArray()
      for argument in instruction.typeArgs: attributes["typeArgs"].add(%encodeType(argument))
    if instruction.mask.len > 0: attributes["mask"] = %instruction.mask
    %* {"op": operations[instruction.kind.ord], "attributes": attributes}
  proc encodeBlock(basicBlock: Block): JsonNode =
    result = %* {"id": basicBlock.label, "parameters": newJArray(),
      "instructions": newJArray(), "terminator": encodeInstruction(basicBlock.term)}
    for parameter in basicBlock.params: result["parameters"].add(encodeValue(parameter))
    for instruction in basicBlock.instrs: result["instructions"].add(encodeInstruction(instruction))
  var foreign = newJArray()
  var externs = module.externs
  externs.sort(proc (left, right: Extern): int = cmp(left.name, right.name))
  for item in externs:
    var params = newJArray()
    for parameter in item.params: params.add(%encodeType(parameter))
    var encoded = %* {"name": item.name, "params": params, "ret": encodeType(item.ret)}
    if item.symbol.len > 0: encoded["symbol"] = %item.symbol
    if item.abi.len > 0: encoded["abi"] = %item.abi
    if item.typeParams.len > 0: encoded["typeParams"] = %item.typeParams
    foreign.add(encoded)
  var functions = newJArray()
  var funcs = module.funcs
  funcs.sort(proc (left, right: Function): int = cmp(left.name, right.name))
  for function in funcs:
    var params = newJArray(); var blocks = newJArray()
    for parameter in function.params: params.add(encodeValue(parameter))
    for basicBlock in function.blocks: blocks.add(encodeBlock(basicBlock))
    var encoded = %* {"name": function.name, "public": function.public,
      "params": params, "ret": encodeType(function.ret), "blocks": blocks}
    if function.line != 0: encoded["line"] = %function.line
    if function.abi.len > 0: encoded["abi"] = %function.abi
    if function.attributes.len > 0: encoded["attributes"] = %function.attributes
    if function.typeParams.len > 0: encoded["typeParams"] = %function.typeParams
    if function.derives.len > 0: encoded["derives"] = %function.derives
    functions.add(encoded)
  var declarations = newJArray()
  var declaredTypes = module.types
  declaredTypes.sort(proc (left, right: TypeDecl): int = cmp(left.name, right.name))
  for declaration in declaredTypes:
    declarations.add(%* {"name": declaration.name, "type": encodeType(declaration.type)})
  var envelope = %* {"format": "foo.ir", "version": 1,
    "stage": (if module.stage.len > 0: module.stage else: "@foo"),
    "unit": {"package": (if module.unitPackage.len > 0: module.unitPackage else: module.name),
      "path": (if module.unitPath.len > 0: module.unitPath else: "main.iv")},
    "requires": (if module.requires.len > 0: module.requires else: "base"),
    "types": definitions, "declarations": declarations, "constants": constants,
    "regions": %module.regions, "traces": %module.traces,
    "foreign": foreign, "native": %module.native, "residue": %module.residue,
    "functions": functions}
  if module.target.len > 0: envelope["target"] = %module.target
  else: envelope["target"] = newJNull()
  if module.storage.len > 0:
    envelope["storage"] = newJArray()
    var storage = module.storage
    storage.sort(proc (left, right: Storage): int = cmp(left.name, right.name))
    for item in storage:
      envelope["storage"].add(%* {"name": item.name, "public": item.public, "value": encodeValue(item.value)})
  $envelope
