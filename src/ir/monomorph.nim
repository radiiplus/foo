import std/[sequtils, sets, strutils, tables]
import ./[kind, node, valid]

type
  OptimizeOptions* = object
    inline*: bool
    target*: string
    cpu*: string
  OptimizeResult* = object
    module*: Module
    expressions*: int
    functions*: int
    dead*: int
    inlined*: int

proc cloneType(value: `Type`; seen: var Table[pointer, `Type`]): `Type` =
  if value == nil: return nil
  let identity = cast[pointer](value)
  if seen.hasKey(identity): return seen[identity]
  result = `Type`(kind: value.kind, name: value.name, width: value.width,
    abi: value.abi, attributes: value.attributes, volatile: value.volatile,
    constant: value.constant, fields: initOrderedTable[string, `Type`](),
    fieldAttrs: value.fieldAttrs, variants: initOrderedTable[string, `Type`]())
  seen[identity] = result
  result.elem = cloneType(value.elem, seen)
  for parameter in value.params: result.params.add(cloneType(parameter, seen))
  result.ret = cloneType(value.ret, seen)
  for name, field in value.fields: result.fields[name] = cloneType(field, seen)
  for name, variant in value.variants: result.variants[name] = cloneType(variant, seen)

proc cloneValue(value: Value; seen: var Table[pointer, `Type`]): Value =
  Value(kind: value.kind, name: value.name, bits: value.bits,
    `type`: cloneType(value.type, seen))

proc cloneInstruction(value: Instruction; seen: var Table[pointer, `Type`]): Instruction
proc cloneBlock(value: Block; seen: var Table[pointer, `Type`]): Block =
  if value == nil: return nil
  result = Block(label: value.label)
  for parameter in value.params: result.params.add(cloneValue(parameter, seen))
  for instruction in value.instrs: result.instrs.add(cloneInstruction(instruction, seen))
  result.term = cloneInstruction(value.term, seen)

proc cloneInstruction(value: Instruction; seen: var Table[pointer, `Type`]): Instruction =
  if value == nil: return nil
  result = Instruction(kind: value.kind, memory: value.memory, op: value.op,
    field: value.field, panic: value.panic, trace: value.trace,
    effects: value.effects, span: value.span, error: value.error,
    symbol: value.symbol, region: value.region, `func`: value.func,
    abi: value.abi, attributes: value.attributes, label: value.label,
    trueLabel: value.trueLabel, falseLabel: value.falseLabel, msg: value.msg,
    handler: value.handler, path: value.path, evalBody: value.evalBody,
    mask: value.mask, reduceOp: value.reduceOp, code: value.code)
  result.dest = cloneValue(value.dest, seen); result.target = cloneValue(value.target, seen)
  result.ptr = cloneValue(value.ptr, seen); result.val = cloneValue(value.val, seen)
  result.val2 = cloneValue(value.val2, seen); result.callee = cloneValue(value.callee, seen)
  result.cond = cloneValue(value.cond, seen); result.value = cloneValue(value.value, seen)
  result.expr = cloneValue(value.expr, seen)
  for item in value.args: result.args.add(cloneValue(item, seen))
  for item in value.trueArgs: result.trueArgs.add(cloneValue(item, seen))
  for item in value.falseArgs: result.falseArgs.add(cloneValue(item, seen))
  for edge in value.blocks: result.blocks.add((label: edge.label, value: cloneValue(edge.value, seen)))
  result.fallback = cloneBlock(value.fallback, seen)
  result.typeArg = cloneType(value.typeArg, seen)
  for item in value.typeArgs: result.typeArgs.add(cloneType(item, seen))

proc cloneFunction(value: node.Function; seen: var Table[pointer, `Type`]): node.Function =
  result = node.Function(public: value.public, line: value.line, name: value.name,
    abi: value.abi, attributes: value.attributes, typeParams: value.typeParams,
    ret: cloneType(value.ret, seen), derives: value.derives)
  for parameter in value.params: result.params.add(cloneValue(parameter, seen))
  for basicBlock in value.blocks: result.blocks.add(cloneBlock(basicBlock, seen))

proc cloneModule*(input: Module): Module =
  var seen = initTable[pointer, `Type`]()
  result = Module(version: input.version, stage: input.stage, name: input.name,
    unitPackage: input.unitPackage, unitPath: input.unitPath, target: input.target,
    requires: input.requires, regions: input.regions, traces: input.traces,
    native: input.native, residue: input.residue)
  for item in input.storage:
    result.storage.add(Storage(name: item.name, public: item.public,
      value: cloneValue(item.value, seen)))
  for item in input.types:
    result.types.add(TypeDecl(name: item.name, `type`: cloneType(item.type, seen)))
  for item in input.externs:
    var copy = Extern(typeParams: item.typeParams, symbol: item.symbol,
      name: item.name, abi: item.abi, ret: cloneType(item.ret, seen))
    for parameter in item.params: copy.params.add(cloneType(parameter, seen))
    result.externs.add(copy)
  for function in input.funcs: result.funcs.add(cloneFunction(function, seen))

proc walk(function: node.Function; visit: proc(instruction: Instruction) {.closure.}) =
  var pending = function.blocks
  var index = 0
  while index < pending.len:
    let basicBlock = pending[index]; inc index
    for instruction in basicBlock.instrs:
      visit(instruction)
      if instruction.fallback != nil: pending.add(instruction.fallback)
    if basicBlock.term != nil: visit(basicBlock.term)

proc prepare*(input: Module): Module =
  result = cloneModule(input)
  for function in result.funcs:
    var normal = initHashSet[string]()
    var exceptional = initHashSet[string]()
    if function.blocks.len > 0: normal.incl(function.blocks[0].label)
    for basicBlock in function.blocks:
      if basicBlock.term != nil:
        if basicBlock.term.label.len > 0: normal.incl(basicBlock.term.label)
        if basicBlock.term.trueLabel.len > 0: normal.incl(basicBlock.term.trueLabel)
        if basicBlock.term.falseLabel.len > 0: normal.incl(basicBlock.term.falseLabel)
      for instruction in basicBlock.instrs:
        if instruction.panic.len > 0: exceptional.incl(instruction.panic)
        if instruction.kind == InstrKind.Thread and instruction.func.len > 0:
          instruction.kind = InstrKind.Call
    var retained: seq[Block]
    for basicBlock in function.blocks:
      if basicBlock.label in normal or basicBlock.label notin exceptional:
        retained.add(basicBlock)
    function.blocks = retained

proc operands(instruction: Instruction): seq[Value] =
  if instruction.val.name.len > 0: result.add(instruction.val)
  if instruction.val2.name.len > 0: result.add(instruction.val2)
  if instruction.ptr.name.len > 0: result.add(instruction.ptr)
  if instruction.target.name.len > 0: result.add(instruction.target)
  if instruction.callee.name.len > 0: result.add(instruction.callee)
  if instruction.cond.name.len > 0: result.add(instruction.cond)
  if instruction.value.name.len > 0: result.add(instruction.value)
  if instruction.expr.name.len > 0: result.add(instruction.expr)
  result.add(instruction.args)
  result.add(instruction.trueArgs)
  result.add(instruction.falseArgs)
  for edge in instruction.blocks: result.add(edge.value)

proc replace(value: var Value; replacements: Table[string, Value]) =
  var seen = initHashSet[string]()
  while value.kind == ValueKind.Reg and replacements.hasKey(value.name) and value.name notin seen:
    seen.incl(value.name)
    value = replacements[value.name]

proc substitute(instruction: Instruction; replacements: Table[string, Value]) =
  replace(instruction.val, replacements); replace(instruction.val2, replacements)
  replace(instruction.ptr, replacements); replace(instruction.target, replacements)
  replace(instruction.callee, replacements); replace(instruction.cond, replacements)
  replace(instruction.value, replacements); replace(instruction.expr, replacements)
  for value in instruction.args.mitems: replace(value, replacements)
  for value in instruction.trueArgs.mitems: replace(value, replacements)
  for value in instruction.falseArgs.mitems: replace(value, replacements)
  for edge in instruction.blocks.mitems: replace(edge.value, replacements)
  if instruction.fallback != nil:
    for child in instruction.fallback.instrs: substitute(child, replacements)
    if instruction.fallback.term != nil: substitute(instruction.fallback.term, replacements)

proc pure(instruction: Instruction): bool =
  if instruction == nil or instruction.dest.name.len == 0 or instruction.effects.len > 0 or
      instruction.panic.len > 0 or instruction.trace.len > 0 or
      instruction.memory.input.len > 0 or instruction.fallback != nil: return false
  if instruction.kind in {InstrKind.Add, InstrKind.Sub, InstrKind.Mul, InstrKind.Div}:
    return instruction.dest.type != nil and instruction.dest.type.kind == TypeKind.Float
  instruction.kind in {InstrKind.Not, InstrKind.Convert, InstrKind.Compare}

proc valueKey(value: Value): string =
  $value.kind & ":" & value.name & ":" & (if value.type == nil: "" else: $value.type.kind & ":" & $value.type.width)
proc instructionKey(instruction: Instruction): string =
  result = $instruction.kind & ":" & instruction.op
  for value in operands(instruction): result.add("|" & valueKey(value))
  if instruction.dest.type != nil: result.add("->" & $instruction.dest.type.kind & ":" & $instruction.dest.type.width)

proc optimize*(input: Module; options = OptimizeOptions()): OptimizeResult =
  result.module = cloneModule(input)
  for function in result.module.funcs:
    var replacements = initTable[string, Value]()
    for basicBlock in function.blocks:
      var seen = initTable[string, Value]()
      var retained: seq[Instruction]
      for instruction in basicBlock.instrs:
        substitute(instruction, replacements)
        if pure(instruction):
          let key = instructionKey(instruction)
          if seen.hasKey(key):
            replacements[instruction.dest.name] = seen[key]
            inc result.expressions
            continue
          seen[key] = instruction.dest
        else:
          seen.clear()
        retained.add(instruction)
      basicBlock.instrs = retained
      if basicBlock.term != nil: substitute(basicBlock.term, replacements)
    var changed = true
    while changed:
      changed = false
      var used = initHashSet[string]()
      for basicBlock in function.blocks:
        for instruction in basicBlock.instrs:
          for value in operands(instruction):
            if value.kind == ValueKind.Reg: used.incl(value.name)
        if basicBlock.term != nil:
          for value in operands(basicBlock.term):
            if value.kind == ValueKind.Reg: used.incl(value.name)
      for basicBlock in function.blocks:
        var retained: seq[Instruction]
        for instruction in basicBlock.instrs:
          if pure(instruction) and instruction.dest.name notin used:
            inc result.dead; changed = true
          else: retained.add(instruction)
        basicBlock.instrs = retained
  if result.module.version == 1:
    discard seal(result.module)

proc typeKey(value: `Type`; seen: var HashSet[pointer]): string =
  if value == nil: return "void"
  let identity = cast[pointer](value)
  if identity in seen: return value.name
  seen.incl(identity)
  var typeName = ""
  for character in value.name:
    typeName.add(if character.isAlphaNumeric: character else: '_')
  result = $value.kind & (if typeName.len > 0: "_" & typeName else: "")
  if value.width > 0: result.add("_" & $value.width)
  if value.constant: result.add("_const")
  if value.elem != nil: result.add("_" & typeKey(value.elem, seen))
  for parameter in value.params: result.add("_" & typeKey(parameter, seen))
  if value.ret != nil: result.add("_" & typeKey(value.ret, seen))

proc typeKey(value: `Type`): string =
  var seen = initHashSet[pointer]()
  typeKey(value, seen)

proc substituteType(value: `Type`; bindings: Table[string, `Type`];
    seen: var Table[pointer, `Type`]): `Type` =
  if value == nil: return nil
  if value.kind == TypeKind.Struct and bindings.hasKey(value.name): return bindings[value.name]
  let identity = cast[pointer](value)
  if seen.hasKey(identity): return seen[identity]
  result = `Type`(kind: value.kind, name: value.name, width: value.width,
    abi: value.abi, attributes: value.attributes, volatile: value.volatile,
    constant: value.constant, fields: initOrderedTable[string, `Type`](),
    fieldAttrs: value.fieldAttrs, variants: initOrderedTable[string, `Type`]())
  seen[identity] = result
  result.elem = substituteType(value.elem, bindings, seen)
  for parameter in value.params: result.params.add(substituteType(parameter, bindings, seen))
  result.ret = substituteType(value.ret, bindings, seen)
  for name, field in value.fields: result.fields[name] = substituteType(field, bindings, seen)
  for name, variant in value.variants: result.variants[name] = substituteType(variant, bindings, seen)

proc specializeValue(value: var Value; bindings: Table[string, `Type`];
    seen: var Table[pointer, `Type`]) =
  value.type = substituteType(value.type, bindings, seen)

proc specializeFunction(function: node.Function; bindings: Table[string, `Type`]) =
  var seen = initTable[pointer, `Type`]()
  for parameter in function.params.mitems: specializeValue(parameter, bindings, seen)
  function.ret = substituteType(function.ret, bindings, seen)
  function.typeParams = @[]
  function.walk(proc(instruction: Instruction) =
    specializeValue(instruction.dest, bindings, seen)
    specializeValue(instruction.val, bindings, seen)
    specializeValue(instruction.val2, bindings, seen)
    specializeValue(instruction.ptr, bindings, seen)
    specializeValue(instruction.target, bindings, seen)
    specializeValue(instruction.callee, bindings, seen)
    specializeValue(instruction.cond, bindings, seen)
    specializeValue(instruction.value, bindings, seen)
    specializeValue(instruction.expr, bindings, seen)
    for value in instruction.args.mitems: specializeValue(value, bindings, seen)
    for value in instruction.trueArgs.mitems: specializeValue(value, bindings, seen)
    for value in instruction.falseArgs.mitems: specializeValue(value, bindings, seen)
    instruction.typeArg = substituteType(instruction.typeArg, bindings, seen)
    for typ in instruction.typeArgs.mitems: typ = substituteType(typ, bindings, seen))

proc monomorphize*(input: Module): Module =
  result = cloneModule(input)
  var genericFunctions = initTable[string, node.Function]()
  var genericExterns = initTable[string, Extern]()
  var functions: seq[node.Function]
  for function in result.funcs:
    if function.typeParams.len > 0: genericFunctions[function.name] = function
    else: functions.add(function)
  var externs: seq[Extern]
  for external in result.externs:
    if external.typeParams.len > 0: genericExterns[external.name] = external
    else: externs.add(external)
  proc isGeneric(name: string): bool =
    genericFunctions.hasKey(name) or genericExterns.hasKey(name)
  var instances = initTable[string, string]()
  var specializedTraces: seq[Trace]
  var queue: seq[Instruction]
  for function in functions:
    function.walk(proc(instruction: Instruction) =
      if instruction.kind == InstrKind.Call and isGeneric(instruction.func):
        queue.add(instruction))
  var position = 0
  while position < queue.len:
    let call = queue[position]; inc position
    let originalName = call.func
    let parameters = if genericFunctions.hasKey(originalName):
      genericFunctions[originalName].typeParams
      else: genericExterns[originalName].typeParams
    if call.typeArgs.len != parameters.len:
      raise newException(ValueError, "Generic function '" & originalName &
        "' needs " & $parameters.len & " type arguments")
    var key = originalName
    for typ in call.typeArgs: key.add("_" & typeKey(typ))
    if not instances.hasKey(key):
      if instances.len >= 4096:
        raise newException(ValueError,
          "Generic specialization exceeds 4096 instances; check for expanding recursive type arguments")
      var bindings = initTable[string, `Type`]()
      for index, parameter in parameters: bindings[parameter] = call.typeArgs[index]
      let instanceName = key
      instances[key] = instanceName
      if genericExterns.hasKey(originalName):
        let original = genericExterns[originalName]
        var seen = initTable[pointer, `Type`]()
        var clone = Extern(name: instanceName,
          symbol: if original.symbol.len > 0: original.symbol else: original.name,
          abi: original.abi,
          ret: substituteType(original.ret, bindings, seen))
        for parameter in original.params:
          clone.params.add(substituteType(parameter, bindings, seen))
        externs.add(clone)
      else:
        let original = genericFunctions[originalName]
        var cloneSeen = initTable[pointer, `Type`]()
        var clone = cloneFunction(original, cloneSeen)
        clone.name = instanceName
        specializeFunction(clone, bindings)
        functions.add(clone)
        clone.walk(proc(instruction: Instruction) =
          if instruction.trace.len > 0:
            let suffix = if instruction.trace.startsWith(originalName):
              instruction.trace[originalName.len .. ^1]
            else: ".trace"
            instruction.trace = instanceName & suffix
            if not specializedTraces.anyIt(it.id == instruction.trace):
              specializedTraces.add(Trace(id: instruction.trace,
                `function`: instanceName))
          if instruction.kind == InstrKind.Call and isGeneric(instruction.func):
            queue.add(instruction))
    call.func = instances[key]
    call.typeArgs = @[]
  result.funcs = functions
  result.externs = externs
  var genericNames = initHashSet[string]()
  for name in genericFunctions.keys: genericNames.incl(name)
  for name in genericExterns.keys: genericNames.incl(name)
  var traces: seq[Trace]
  for trace in result.traces:
    if trace.function notin genericNames: traces.add(trace)
  traces.add(specializedTraces)
  result.traces = traces

  var visited = initHashSet[pointer]()
  var declarations = initOrderedTable[string, TypeDecl]()
  for declaration in result.types: declarations[declaration.name] = declaration
  proc specializeNamed(value: `Type`) =
    if value == nil: return
    let identity = cast[pointer](value)
    if identity in visited: return
    visited.incl(identity)
    specializeNamed(value.elem)
    for parameter in value.params: specializeNamed(parameter)
    specializeNamed(value.ret)
    for field in value.fields.values: specializeNamed(field)
    for variant in value.variants.values: specializeNamed(variant)
    let bracket = value.name.find('[')
    if value.kind in {TypeKind.Struct, TypeKind.PackedStruct,
        TypeKind.TaggedUnion} and bracket >= 0 and value.params.len > 0:
      var suffix: seq[string]
      for parameter in value.params: suffix.add(typeKey(parameter))
      value.name = value.name[0 ..< bracket] & "__" & suffix.join("__")
      declarations[value.name] = TypeDecl(name: value.name, `type`: value)
  proc specializeNamed(value: var Value) = specializeNamed(value.type)
  proc specializeNamed(instruction: Instruction) =
    if instruction == nil: return
    specializeNamed(instruction.dest); specializeNamed(instruction.val)
    specializeNamed(instruction.val2); specializeNamed(instruction.ptr)
    specializeNamed(instruction.target); specializeNamed(instruction.callee)
    specializeNamed(instruction.cond); specializeNamed(instruction.value)
    specializeNamed(instruction.expr)
    for value in instruction.args.mitems: specializeNamed(value)
    for value in instruction.trueArgs.mitems: specializeNamed(value)
    for value in instruction.falseArgs.mitems: specializeNamed(value)
    for edge in instruction.blocks.mitems: specializeNamed(edge.value)
    specializeNamed(instruction.typeArg)
    for value in instruction.typeArgs: specializeNamed(value)
    if instruction.fallback != nil:
      for parameter in instruction.fallback.params.mitems: specializeNamed(parameter)
      for child in instruction.fallback.instrs: specializeNamed(child)
      specializeNamed(instruction.fallback.term)
  for declaration in result.types: specializeNamed(declaration.type)
  for item in result.storage.mitems: specializeNamed(item.value)
  for external in result.externs.mitems:
    for parameter in external.params: specializeNamed(parameter)
    specializeNamed(external.ret)
  for function in result.funcs:
    for parameter in function.params.mitems: specializeNamed(parameter)
    specializeNamed(function.ret)
    for basicBlock in function.blocks:
      for parameter in basicBlock.params.mitems: specializeNamed(parameter)
      for instruction in basicBlock.instrs: specializeNamed(instruction)
      specializeNamed(basicBlock.term)
  result.types = @[]
  for declaration in declarations.values: result.types.add(declaration)
