import std/json
import std/sets
import std/tables
import std/strutils
import std/sequtils
import ../ir/node
import ../ir/kind
import ../opt/substrate

type Boundary = object
  id: string
  stage: string
  code: string
  abi: string
  effects: seq[string]
  bindings: seq[string]

proc identifier(value: string): string =
  if value.len == 0 or not (value[0].isAlphaAscii or value[0] == '_') or value.anyIt(not (it.isAlphaNumeric or it == '_')):
    raise newException(ValueError, "Invalid native binding '" & value & "'")
  value

proc spelling(value: `Type`; declarations: var seq[string]; declared: var HashSet[string]): string =
  if value == nil: return "void"
  case value.kind
  of Shape.Void: "void"
  of Shape.Bool: "bool"
  of Shape.Int, Shape.Uint:
    if value.width notin [8, 16, 32, 64] and value.width != 0: raise newException(ValueError, "Native integer bindings require 8, 16, 32 or 64 bits")
    (if value.kind == Shape.Uint: "u" else: "") & "int" & $(if value.width > 0: value.width else: 64) & "_t"
  of Shape.Float: (if value.width == 32: "float" else: "double")
  of Shape.Ptr: spelling(value.elem, declarations, declared) & " *"
  of Shape.Opaque: "void"
  of Shape.ExternStruct, Shape.ExternUnion:
    let name = identifier(value.name)
    if name notin declared:
      declared.incl(name)
      let tag = if value.kind == Shape.ExternUnion: "union" else: "struct"
      declarations.add("typedef " & tag & " " & name & " " & name & ";")
      var fields: seq[string]
      for fieldName, member in value.fields.pairs: fields.add(spelling(member, declarations, declared) & " " & identifier(fieldName) & ";")
      declarations.add(tag & " " & name & " { " & fields.join(" ") & " };")
    name
  of Shape.Function:
    let name = "foo_callback_" & $declared.len
    declared.incl(name)
    var params: seq[string]
    for param in value.params: params.add(spelling(param, declarations, declared))
    declarations.add("typedef " & spelling(value.ret, declarations, declared) & " (*" & name & ")(" & (if params.len > 0: params.join(", ") else: "void") & ");")
    name
  of Shape.Slice:
    let name = "foo_slice_" & $declared.len
    declared.incl(name)
    declarations.add("typedef struct { " & (if value.constant: "const " else: "") & spelling(value.elem, declarations, declared) & " *data; size_t len; } " & name & ";")
    name
  else: raise newException(ValueError, "Native bindings require C-compatible values")

proc escape*(input: Module; options: substrate.Selection): tuple[module: Module, code: string,
    decisions: seq[Decision]] =
  let bound = `bind`(input, options)
  var module = bound.module
  var contracts = initTable[string, Boundary]()
  var inlined = initHashSet[string]()
  for contract in module.native:
    var item = Boundary(id: contract.id, stage: contract.stage, code: contract.code, abi: contract.abi, effects: contract.effects)
    if contract.abi == "foo.native:1":
      let payload = parseJson(contract.code)
      if payload.hasKey("source"): item.code = payload["source"].getStr
      if payload.hasKey("parameters"):
        for parameter in payload["parameters"].items: item.bindings.add(parameter.getStr)
    contracts[contract.id] = item

  var invoked = initHashSet[string]()
  for fn in module.funcs:
    var pending = fn.blocks
    var position = 0
    while position < pending.len:
      let section = pending[position]
      inc position
      var instructions = section.instrs
      instructions.add(section.term)
      for instruction in instructions:
        if instruction == nil: continue
        if instruction.fallback != nil: pending.add(instruction.fallback)
        pending.add(instruction.fallbackBlocks)
        if instruction.kind != Opcode.Native: continue
        if instruction.op in ["machine:align", "machine:system"] or
            instruction.op.startsWith("machine:register:"): continue
        if instruction.symbol notin contracts: raise newException(ValueError, "Native operation has no contract")
        var contract = contracts[instruction.symbol]
        if "naked" in fn.attributes and contract.stage == "@asm":
          inlined.incl(contract.id)
          continue
        let symbol = "foo_escape_" & contract.id
        if contract.id notin invoked:
          var params: seq[`Type`]
          for argument in instruction.args: params.add(argument.`type`)
          let returns = if instruction.dest.`type` != nil: instruction.dest.`type` else: `Type`(kind: Shape.Void)
          module.externs.add(Extern(name: symbol, symbol: symbol, abi: "c", params: params, ret: returns))
        if contract.abi.startsWith("machine:"):
          contract.bindings.setLen(0)
          for index in 0 ..< instruction.args.len: contract.bindings.add("arg" & $index)
          contracts[contract.id] = contract
        invoked.incl(contract.id)
        instruction.kind = Opcode.Call
        instruction.`func` = symbol
        instruction.abi = "c"
        instruction.symbol = symbol
        if instruction.args.len == 0: instruction.args = @[]
        instruction.code = ""

  var declarations: seq[string]
  var declared = initHashSet[string]()
  var definitions, includes: seq[string]
  for contract in contracts.values:
    if contract.id in inlined: continue
    var external: Extern
    var found = false
    for declaration in module.externs:
      if declaration.symbol == contract.id or declaration.symbol == "foo_escape_" & contract.id:
        external = declaration; found = true; break
    let wrapped = contract.id in invoked or contract.bindings.len > 0
    if not wrapped:
      definitions.add(native(Contract(id: contract.id, stage: contract.stage, code: contract.code, abi: contract.abi, effects: contract.effects), options, true))
      continue
    let name = if found and external.symbol.len > 0: external.symbol else: "foo_escape_" & contract.id
    var params: seq[string]
    if contract.bindings.len > 0 and found:
      for index, binding in contract.bindings: params.add(spelling(external.params[index], declarations, declared) & " " & identifier(binding))
    let returns = if found: spelling(external.ret, declarations, declared) else: "void"
    var lines: seq[string]
    for line in contract.code.splitLines:
      if line.strip.startsWith("#include"): includes.add(line.strip)
      else: lines.add(line)
    var body = lines.join("\n")
    if contract.abi.startsWith("machine:"):
      raise newException(ValueError, "QBE does not yet support machine ABI operations")
    elif contract.stage == "@asm" and body.strip.startsWith("\""):
      if returns != "void" and "result" in contract.bindings:
        raise newException(ValueError,
          "Assembly reserves result for its return binding; choose another parameter name")
      body = (if returns == "void": "" else: returns & " result;\n") & "__asm__ __volatile__(" & body & ");" & (if returns == "void": "" else: "\nreturn result;")
    else:
      body = native(Contract(id: contract.id, stage: contract.stage, code: body, abi: contract.abi, effects: contract.effects), options)
    if contract.stage == "@asm" and returns != "void" and
        not lines.join("\n").strip.startsWith("\""):
      raise newException(ValueError,
        "Assembly returning a value needs a constrained output named result")
    definitions.add(returns & " " & identifier(name) & "(" & (if params.len > 0: params.join(", ") else: "void") & ") {\n" & body & "\n}")
  module.native = module.native.filterIt(it.id in inlined)
  result.module = module
  result.decisions = bound.decisions
  result.code = if definitions.len > 0: "#include <stdint.h>\n#include <stdbool.h>\n" &
    includes.join("\n") & "\n" & declarations.join("\n") & "\n" &
    definitions.join("\n\n") & "\n" else: ""
