import std/[algorithm, base64, json, strutils, tables, unicode]
import ./[kind, node]

proc encode*(module: Module): string

proc spelling(value: `Type`): string =
  if value == nil: return "void"
  case value.kind
  of Shape.Int: (if value.width > 0: "int" & $value.width else: "int")
  of Shape.Uint: (if value.width > 0: "uint" & $value.width else: "uint")
  of Shape.Float: (if value.width > 0: "float" & $value.width else: "float")
  of Shape.Bool: "bool"
  of Shape.Ptr: "ptr<" & spelling(value.elem) & ">"
  of Shape.Slice: (if value.constant: "text<" else: "slice<") & spelling(value.elem) & ">"
  of Shape.Optional: "optional<" & spelling(value.elem) & ">"
  of Shape.Failable: "failable<" & spelling(value.elem) & ">"
  of Shape.Array: "[" & $value.width & "]" & spelling(value.elem)
  of Shape.Struct: (if value.name.len > 0: value.name else: "struct")
  of Shape.Void: "void"
  of Shape.Error: "error"
  of Shape.Vector: "vec<" & $value.width & "," & spelling(value.elem) & ">"
  of Shape.TaggedUnion: (if value.name.len > 0: value.name else: "choice")
  of Shape.PackedStruct: (if value.name.len > 0: value.name else: "packed")
  of Shape.ExternUnion: (if value.name.len > 0: value.name else: "c_union")
  of Shape.ExternStruct: (if value.name.len > 0: value.name else: "c_record")
  of Shape.Opaque: (if value.name.len > 0: value.name else: "opaque")
  of Shape.Function:
    var params: seq[string]
    for parameter in value.params: params.add(spelling(parameter))
    "fn<" & params.join(",") & "," & spelling(value.ret) & ">"
  of Shape.Memory: "memory"
  of Shape.Region: "region"
  of Shape.Trace: "trace"

proc literal(value: Value): string =
  case value.kind
  of Flavor.Reg: "%" & value.name
  of Flavor.Const: value.name
  of Flavor.Global: "@" & value.name

proc instruction(instruction: Instruction): string =
  if instruction == nil: return ""
  let dest = if instruction.dest.name.len > 0: literal(instruction.dest) & " = " else: ""
  case instruction.kind
  of Opcode.Alloc: dest & "alloc " & instruction.region & " " & spelling(instruction.dest.type.elem)
  of Opcode.Load: dest & "load " & literal(instruction.ptr)
  of Opcode.Store: "store " & literal(instruction.val) & ", " & literal(instruction.ptr)
  of Opcode.Add: dest & "add " & literal(instruction.val) & ", " & literal(instruction.val2)
  of Opcode.Sub: dest & "sub " & literal(instruction.val) & ", " & literal(instruction.val2)
  of Opcode.Mul: dest & "mul " & literal(instruction.val) & ", " & literal(instruction.val2)
  of Opcode.Div: dest & "div " & literal(instruction.val) & ", " & literal(instruction.val2)
  of Opcode.Remainder: dest & "remainder " & literal(instruction.val) & ", " & literal(instruction.val2)
  of Opcode.Bit: dest & "bit " & instruction.op & " " & literal(instruction.val) &
    (if instruction.op == "not": "" else: ", " & literal(instruction.val2))
  of Opcode.Call:
    var args: seq[string]
    for argument in instruction.args: args.add(literal(argument))
    var arguments = ""
    if instruction.arguments.len > 0:
      var values: seq[string]
      for typ in instruction.arguments: values.add(spelling(typ))
      arguments = "[" & values.join(", ") & "]"
    let callee = if instruction.callee.name.len > 0: literal(instruction.callee) else: "@" & instruction.func
    dest & "call " & callee & arguments & "(" & args.join(", ") & ")"
  of Opcode.Jump: "jump " & instruction.label
  of Opcode.Cjump: "cjump " & literal(instruction.cond) & ", " & instruction.yes & ", " & instruction.no
  of Opcode.Return: (if instruction.value.name.len > 0: "return " & literal(instruction.value) else: "return")
  of Opcode.Panic: "panic \"" & instruction.msg & "\""
  of Opcode.Try: dest & "try " & literal(instruction.expr) & (if instruction.handler.len > 0: ", " & instruction.handler else: "")
  of Opcode.Catch, Opcode.Defer:
    let body = instruction.fallback
    var lines: seq[string]
    var sections: seq[Block]
    if body != nil: sections.add(body)
    sections.add(instruction.fallbackBlocks)
    for section in sections:
      lines.add(section.label & ":")
      for child in section.instrs: lines.add("  " & instruction(child))
      if section.term != nil: lines.add("  " & instruction(section.term))
    dest & (if instruction.kind == Opcode.Catch: "catch " & literal(instruction.val) else: "defer" & (if instruction.error: " error" else: "")) &
      " {\n" & lines.join("\n") & "\n}"
  of Opcode.Phi:
    var sources: seq[string]
    for source in instruction.blocks: sources.add("[" & source.label & ": " & literal(source.value) & "]")
    dest & "phi " & sources.join(", ")
  of Opcode.Eval: dest & "eval \"" & instruction.evaluation & "\""
  of Opcode.Reflect: dest & "reflect " & spelling(instruction.argument)
  of Opcode.Embed: dest & "embed \"" & instruction.path & "\""
  of Opcode.Splat: dest & "splat " & literal(instruction.val)
  of Opcode.Shuffle:
    var mask: seq[string]
    for lane in instruction.mask: mask.add($lane)
    dest & "shuffle " & literal(instruction.val) & ", " & literal(instruction.val2) & ", " & mask.join(", ")
  of Opcode.Gather: dest & "gather " & literal(instruction.val) & ", " & literal(instruction.val2)
  of Opcode.Scatter: dest & "scatter " & literal(instruction.val) & ", " &
    literal(instruction.val2) & ", " & literal(instruction.args[0])
  of Opcode.Select: dest & "select " & literal(instruction.cond) & ", " & literal(instruction.val) & ", " & literal(instruction.val2)
  of Opcode.Reduce: dest & "reduce " & instruction.reduction.toLowerAscii & ", " & literal(instruction.val)
  else: dest & operations[instruction.kind.ord]

proc print*(module: Module): string =
  if module.version == 1: return encode(module)
  var output = "module " & module.name & " {\n\n"
  for foreign in module.externs:
    var params: seq[string]
    for parameter in foreign.params: params.add(spelling(parameter))
    output.add("  extern \"" & foreign.abi & "\" fn @" & foreign.name & "(" & params.join(", ") & ") -> " & spelling(foreign.ret) & "\n")
  if module.externs.len > 0: output.add("\n")
  for function in module.funcs:
    var params: seq[string]
    for parameter in function.params: params.add(literal(parameter) & ": " & spelling(parameter.type))
    let generics = if function.generics.len > 0: "[" & function.generics.join(", ") & "]" else: ""
    output.add("fn @" & function.name & generics & "(" & params.join(", ") & ") -> " & spelling(function.ret) & " {\n")
    for section in function.blocks:
      output.add("\n" & section.label & ":\n")
      for instruction in section.instrs: output.add("  " & instruction(instruction) & "\n")
      output.add("  " & instruction(section.term) & "\n")
    output.add("}\n\n")
  output.strip & "\n}"

proc encode*(module: Module): string =
  var definitions = newJArray()
  var known = initTable[pointer, string]()
  proc encode(value: `Type`): string =
    if value == nil: return ""
    let identity = cast[pointer](value)
    if known.hasKey(identity): return known[identity]
    let id = "t" & $known.len
    known[identity] = id
    let index = definitions.len
    definitions.add(newJNull())
    let names = ["integer", "decimal", "bool", "pointer", "array", "record",
      "unit", "error", "vector", "choice", "packed", "union", "opaque",
      "function", "integer", "record", "sequence", "optional", "failable",
      "memory", "region", "trace"]
    var definition = newJObject()
    definition["kind"] = %names[value.kind.ord]
    if value.name.len > 0: definition["name"] = %value.name
    if value.kind in {Shape.Int, Shape.Uint, Shape.Float}:
      definition["bits"] = %(if value.width > 0: value.width elif value.kind == Shape.Float: 64 else: 32)
    if value.kind in {Shape.Array, Shape.Vector}:
      definition["width"] = %value.width
    if value.kind in {Shape.Int, Shape.Uint}: definition["signed"] = %(value.kind == Shape.Int)
    if value.kind == Shape.ExternStruct: definition["layout"] = %"c"
    if value.abi.len > 0: definition["abi"] = %value.abi
    if value.attributes.len > 0: definition["attributes"] = %value.attributes
    if value.volatile: definition["volatile"] = %true
    if value.constant: definition["constant"] = %true
    if value.elem != nil: definition["element"] = %encode(value.elem)
    if value.params.len > 0:
      definition["parameters"] = newJArray()
      for parameter in value.params: definition["parameters"].add(%encode(parameter))
    if value.ret != nil: definition["result"] = %encode(value.ret)
    if value.fields.len > 0:
      definition["fields"] = newJArray()
      var names: seq[string]
      for name in value.fields.keys: names.add(name)
      names.sort()
      for name in names: definition["fields"].add(%* {"name": name, "type": encode(value.fields[name])})
    if value.annotations.len > 0:
      definition["fieldAttrs"] = newJArray()
      var names: seq[string]
      for name in value.annotations.keys: names.add(name)
      names.sort()
      for name in names: definition["fieldAttrs"].add(%* [name, value.annotations[name]])
    if value.variants.len > 0:
      definition["variants"] = newJArray()
      var names: seq[string]
      for name in value.variants.keys: names.add(name)
      names.sort()
      for name in names:
        definition["variants"].add(%* {"name": name,
          "type": (if value.variants[name] == nil: newJNull() else: %encode(value.variants[name]))})
    definitions.elems[index] = %* {"id": id, "definition": definition}
    id
  var constants = newJArray()
  var interned = initTable[string, string]()
  proc encode(value: Value): JsonNode =
    let reference = encode(value.type)
    if value.kind == Flavor.Const:
      var encoding = "literal"
      var data = value.name
      if value.type != nil and value.bits.len > 0 and value.type.kind in
          {Shape.Array, Shape.Vector, Shape.Struct, Shape.ExternStruct,
           Shape.TaggedUnion, Shape.ExternUnion, Shape.PackedStruct}:
        encoding = "bits"
        data = value.bits
      elif value.name != "undefined" and value.type != nil and value.type.kind in {Shape.Int, Shape.Uint}:
        encoding = "integer"
        data = value.name.replace("_", "")
      elif value.name != "undefined" and value.type != nil and value.type.kind == Shape.Float:
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
      elif value.name != "undefined" and value.type != nil and value.type.kind == Shape.Slice:
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
    if value.kind == Flavor.Reg: %* {"register": value.name, "type": reference}
    else: %* {"symbol": value.name, "type": reference}
  proc encode(instruction: Instruction): JsonNode
  proc encode(section: Block): JsonNode
  proc encode(instruction: Instruction): JsonNode =
    var attributes = newJObject()
    if instruction == nil: return %* {"op": "", "attributes": attributes}
    if instruction.dest.name.len > 0: attributes["dest"] = encode(instruction.dest)
    if instruction.ptr.name.len > 0: attributes["ptr"] = encode(instruction.ptr)
    if instruction.target.name.len > 0: attributes["target"] = encode(instruction.target)
    if instruction.callee.name.len > 0: attributes["callee"] = encode(instruction.callee)
    if instruction.val.name.len > 0: attributes["val"] = encode(instruction.val)
    if instruction.val2.name.len > 0: attributes["val2"] = encode(instruction.val2)
    if instruction.value.name.len > 0: attributes["value"] = encode(instruction.value)
    if instruction.cond.name.len > 0: attributes["cond"] = encode(instruction.cond)
    if instruction.expr.name.len > 0: attributes["expr"] = encode(instruction.expr)
    if instruction.memory.input.len > 0 or instruction.memory.output.len > 0:
      attributes["memory"] = newJObject()
      if instruction.memory.input.len > 0: attributes["memory"]["input"] = %instruction.memory.input
      if instruction.memory.output.len > 0: attributes["memory"]["output"] = %instruction.memory.output
    if instruction.positive.len > 0:
      attributes["trueArgs"] = newJArray()
      for argument in instruction.positive: attributes["trueArgs"].add(encode(argument))
    if instruction.negative.len > 0:
      attributes["falseArgs"] = newJArray()
      for argument in instruction.negative: attributes["falseArgs"].add(encode(argument))
    if instruction.op.len > 0: attributes["op"] = %instruction.op
    if instruction.field.len > 0: attributes["field"] = %instruction.field
    if instruction.panic.len > 0: attributes["panic"] = %instruction.panic
    if instruction.trace.len > 0: attributes["trace"] = %instruction.trace
    if instruction.effects.len > 0: attributes["effects"] = %instruction.effects
    if instruction.span.file.len > 0 or instruction.span.start != 0 or instruction.span.`end` != 0:
      attributes["span"] = %* {"file": instruction.span.file, "start": instruction.span.start, "end": instruction.span.`end`}
    if instruction.error: attributes["error"] = %true
    if instruction.fallback != nil: attributes["fallback"] = encode(instruction.fallback)
    if instruction.fallbackBlocks.len > 0:
      attributes["fallbackBlocks"] = newJArray()
      for section in instruction.fallbackBlocks:
        attributes["fallbackBlocks"].add(encode(section))
    if instruction.symbol.len > 0: attributes["symbol"] = %instruction.symbol
    if instruction.region.len > 0: attributes["region"] = %instruction.region
    if instruction.func.len > 0: attributes["func"] = %instruction.func
    if instruction.abi.len > 0: attributes["abi"] = %instruction.abi
    if instruction.attributes.len > 0: attributes["attributes"] = %instruction.attributes
    if instruction.label.len > 0: attributes["label"] = %instruction.label
    if instruction.yes.len > 0: attributes["trueLabel"] = %instruction.yes
    if instruction.no.len > 0: attributes["falseLabel"] = %instruction.no
    if instruction.msg.len > 0: attributes["msg"] = %instruction.msg
    if instruction.handler.len > 0: attributes["handler"] = %instruction.handler
    if instruction.path.len > 0: attributes["path"] = %instruction.path
    if instruction.evaluation.len > 0: attributes["evalBody"] = %instruction.evaluation
    if instruction.reduction.len > 0: attributes["reduceOp"] = %instruction.reduction
    if instruction.code.len > 0: attributes["code"] = %instruction.code
    if instruction.args.len > 0:
      attributes["args"] = newJArray()
      for argument in instruction.args: attributes["args"].add(encode(argument))
    if instruction.blocks.len > 0:
      attributes["blocks"] = newJArray()
      for edge in instruction.blocks:
        attributes["blocks"].add(%* {"label": edge.label, "value": encode(edge.value)})
    if instruction.argument != nil: attributes["typeArg"] = %encode(instruction.argument)
    if instruction.arguments.len > 0:
      attributes["typeArgs"] = newJArray()
      for argument in instruction.arguments: attributes["typeArgs"].add(%encode(argument))
    if instruction.mask.len > 0: attributes["mask"] = %instruction.mask
    %* {"op": operations[instruction.kind.ord], "attributes": attributes}
  proc encode(section: Block): JsonNode =
    result = %* {"id": section.label, "parameters": newJArray(),
      "instructions": newJArray(), "terminator": encode(section.term)}
    for parameter in section.params: result["parameters"].add(encode(parameter))
    for instruction in section.instrs: result["instructions"].add(encode(instruction))
  var foreign = newJArray()
  var externs = module.externs
  externs.sort(proc (left, right: Extern): int = cmp(left.name, right.name))
  for item in externs:
    var params = newJArray()
    for parameter in item.params: params.add(%encode(parameter))
    var encoded = %* {"name": item.name, "params": params, "ret": encode(item.ret)}
    if item.symbol.len > 0: encoded["symbol"] = %item.symbol
    if item.abi.len > 0: encoded["abi"] = %item.abi
    if item.generics.len > 0: encoded["typeParams"] = %item.generics
    foreign.add(encoded)
  var functions = newJArray()
  var funcs = module.funcs
  funcs.sort(proc (left, right: Function): int = cmp(left.name, right.name))
  for function in funcs:
    var params = newJArray(); var blocks = newJArray()
    for parameter in function.params: params.add(encode(parameter))
    for section in function.blocks: blocks.add(encode(section))
    var encoded = %* {"name": function.name, "public": function.public,
      "params": params, "ret": encode(function.ret), "blocks": blocks}
    if function.line != 0: encoded["line"] = %function.line
    if function.abi.len > 0: encoded["abi"] = %function.abi
    if function.attributes.len > 0: encoded["attributes"] = %function.attributes
    if function.generics.len > 0: encoded["typeParams"] = %function.generics
    if function.derives.len > 0: encoded["derives"] = %function.derives
    functions.add(encoded)
  var declarations = newJArray()
  var declared = module.types
  declared.sort(proc (left, right: Definition): int = cmp(left.name, right.name))
  for declaration in declared:
    declarations.add(%* {"name": declaration.name, "type": encode(declaration.type)})
  var envelope = %* {"format": "foo.ir", "version": 1,
    "stage": (if module.stage.len > 0: module.stage else: "@foo"),
    "unit": {"package": (if module.package.len > 0: module.package else: module.name),
      "path": (if module.path.len > 0: module.path else: "main.iv")},
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
      var encoded = %* {"name": item.name, "public": item.public,
        "thread": item.thread, "value": encode(item.value)}
      if item.alignment > 0: encoded["alignment"] = %item.alignment
      if item.section.len > 0: encoded["section"] = %item.section
      envelope["storage"].add(encoded)
  $envelope
