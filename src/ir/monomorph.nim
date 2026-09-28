import std/[sequtils, sets, strutils, tables]
import ./[kind, node, valid]
import ../opt/arch as targetArch
import std/unicode

type
  OptimizeOptions* = object
    inline*: bool
    target*: string
    cpu*: string
    hot*: HashSet[string]
  OptimizeResult* = object
    module*: Module
    expressions*: int
    functions*: int
    dead*: int
    inlined*: int
    boundaries*: int
    allocations*: int
    pipelines*: int
    continuations*: int
    serializations*: int

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
    native: input.native, residue: input.residue,
    optimization: input.optimization)
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
  if instruction.kind in {InstrKind.Add, InstrKind.Sub, InstrKind.Mul,
      InstrKind.Div, InstrKind.Remainder}:
    return instruction.dest.type != nil and instruction.dest.type.kind == TypeKind.Float
  if instruction.kind == InstrKind.Construct:
    return instruction.dest.type != nil and instruction.dest.type.kind != TypeKind.Slice
  instruction.kind in {InstrKind.Not, InstrKind.Convert, InstrKind.Compare,
    InstrKind.Length, InstrKind.Splat, InstrKind.Shuffle, InstrKind.Select,
    InstrKind.Reduce}

proc semanticTypeKey(value: `Type`; active: var HashSet[pointer]): string =
  if value == nil: return "nil"
  let identity = cast[pointer](value)
  if identity in active: return "ref(" & value.name & ")"
  active.incl(identity)
  result = $value.kind & "(" & $value.name.len & ":" & value.name & "," &
    $value.width & "," & $value.constant & "," & $value.volatile & "," &
    $value.abi.len & ":" & value.abi
  for attribute in value.attributes:
    result.add(",a" & $attribute.len & ":" & attribute)
  if value.elem != nil: result.add(",e" & semanticTypeKey(value.elem, active))
  for parameter in value.params:
    result.add(",p" & semanticTypeKey(parameter, active))
  if value.ret != nil: result.add(",r" & semanticTypeKey(value.ret, active))
  for name, fieldType in value.fields:
    result.add(",f" & $name.len & ":" & name & "=" &
      semanticTypeKey(fieldType, active))
    for attribute in value.fieldAttrs.getOrDefault(name):
      result.add("#" & $attribute.len & ":" & attribute)
  for name, variantType in value.variants:
    result.add(",v" & $name.len & ":" & name & "=" &
      semanticTypeKey(variantType, active))
  result.add(")")
  active.excl(identity)

proc semanticTypeKey(value: `Type`): string =
  var active = initHashSet[pointer]()
  semanticTypeKey(value, active)

proc valueKey(value: Value): string =
  $value.kind & ":" & $value.name.len & ":" & value.name & ":" &
    $value.bits.len & ":" & value.bits & ":" & semanticTypeKey(value.type)
proc instructionKey(instruction: Instruction): string =
  result = $instruction.kind & ":" & instruction.op & ":" &
    instruction.field & ":" & instruction.reduceOp
  for item in instruction.mask: result.add("#" & $item)
  for value in operands(instruction): result.add("|" & valueKey(value))
  if instruction.dest.type != nil:
    result.add("->" & semanticTypeKey(instruction.dest.type))

proc pureFunction(function: node.Function): bool =
  if function == nil or function.public or function.name == "main" or
      function.abi.len > 0 or function.attributes.len > 0 or
      function.blocks.len != 1 or function.ret == nil or
      function.ret.kind in {TypeKind.Error, TypeKind.Failable}: return false
  let basicBlock = function.blocks[0]
  if basicBlock == nil or basicBlock.term == nil or
      basicBlock.term.kind != InstrKind.Return: return false
  for parameter in basicBlock.params:
    if parameter.type == nil or parameter.type.kind != TypeKind.Memory: return false
  for instruction in basicBlock.instrs:
    if not pure(instruction): return false
    for value in operands(instruction):
      if value.kind == ValueKind.Global: return false
  basicBlock.term.value.type == nil or basicBlock.term.value.kind != ValueKind.Global

proc canonicalValue(value: Value; names: Table[string, string]): string =
  if value.type == nil: return "none"
  let identity = case value.kind
    of ValueKind.Reg: names.getOrDefault(value.name, "?" & value.name)
    of ValueKind.Const: value.name & ":" & value.bits
    of ValueKind.Global: value.name
  $value.kind & ":" & $identity.len & ":" & identity & ":" &
    semanticTypeKey(value.type)

proc functionKey(function: node.Function): string =
  var names = initTable[string, string]()
  result = "ret=" & semanticTypeKey(function.ret)
  for index, parameter in function.params:
    names[parameter.name] = "p" & $index
    result.add("|param=" & semanticTypeKey(parameter.type))
  var serial = 0
  for instruction in function.blocks[0].instrs:
    result.add("|op=" & $instruction.kind & ":" & instruction.op & ":" &
      instruction.field & ":" & instruction.reduceOp)
    for item in instruction.mask: result.add("#" & $item)
    for value in operands(instruction):
      result.add(";" & canonicalValue(value, names))
    result.add("->" & semanticTypeKey(instruction.dest.type))
    names[instruction.dest.name] = "v" & $serial
    inc serial
  result.add("|return=" & canonicalValue(function.blocks[0].term.value, names))

proc addressTaken(module: Module): HashSet[string] =
  var taken = initHashSet[string]()
  for function in module.funcs:
    function.walk(proc(instruction: Instruction) =
      for value in operands(instruction):
        if value.kind == ValueKind.Global and value.type != nil and
            value.type.kind == TypeKind.Function:
          taken.incl(value.name))
  taken

proc mergeEquivalent(module: Module; protected: HashSet[string]): int =
  var representatives = initTable[string, string]()
  var aliases = initTable[string, string]()
  var retained: seq[node.Function]
  for function in module.funcs:
    if pureFunction(function) and function.name notin protected:
      let key = functionKey(function)
      if representatives.hasKey(key):
        aliases[function.name] = representatives[key]
        inc result
        continue
      representatives[key] = function.name
    retained.add(function)
  if aliases.len == 0: return
  for function in retained:
    function.walk(proc(instruction: Instruction) =
      if aliases.hasKey(instruction.func): instruction.func = aliases[instruction.func])
  module.funcs = retained

proc cost(instruction: Instruction; profile: targetArch.Profile): int =
  case instruction.kind
  of InstrKind.Mul: profile.multiply
  of InstrKind.Div, InstrKind.Remainder: profile.divide
  of InstrKind.Construct: 4
  of InstrKind.Splat, InstrKind.Shuffle, InstrKind.Select, InstrKind.Reduce: 2
  else: 1

proc functionCost(function: node.Function; profile: targetArch.Profile): int =
  for instruction in function.blocks[0].instrs:
    result += cost(instruction, profile)

proc inlineCalls(module: Module; options: OptimizeOptions;
    protected: HashSet[string]; pipelines: var int): int =
  let profile = targetArch.profile(options.target, options.cpu)
  let budget = max(1, profile.budget)
  let maximum = max(4, budget div 4)
  var candidates = initTable[string, node.Function]()
  var costs = initTable[string, int]()
  for function in module.funcs:
    if pureFunction(function) and function.name notin protected:
      let weight = functionCost(function, profile)
      let limit = if function.name in options.hot: maximum * 2 else: maximum
      if weight <= limit:
        candidates[function.name] = function
        costs[function.name] = weight
  for caller in module.funcs:
    var remaining = if caller.name in options.hot: budget * 2 else: budget
    var serial = 0
    var occupied = initHashSet[string]()
    for parameter in caller.params: occupied.incl(parameter.name)
    for basicBlock in caller.blocks:
      for parameter in basicBlock.params: occupied.incl(parameter.name)
      for instruction in basicBlock.instrs:
        if instruction.dest.name.len > 0: occupied.incl(instruction.dest.name)
    proc fresh(): string =
      while true:
        inc serial
        result = "inlined_" & $serial
        if result notin occupied:
          occupied.incl(result)
          return
    var replacements = initTable[string, Value]()
    for basicBlock in caller.blocks:
      var retained: seq[Instruction]
      var previous = ""
      for instruction in basicBlock.instrs:
        let connected = previous.len > 0 and instruction.kind == InstrKind.Call and
          instruction.args.anyIt(it.kind == ValueKind.Reg and it.name == previous)
        substitute(instruction, replacements)
        if instruction.kind != InstrKind.Call or
            not candidates.hasKey(instruction.func) or
            costs[instruction.func] > remaining:
          retained.add(instruction)
          previous = ""
          continue
        let candidate = candidates[instruction.func]
        if instruction.args.len != candidate.params.len:
          retained.add(instruction)
          continue
        let returned = candidate.blocks[0].term.value
        if instruction.dest.type != nil and returned.type == nil:
          retained.add(instruction)
          continue
        var local = initTable[string, Value]()
        for index, parameter in candidate.params:
          local[parameter.name] = instruction.args[index]
        var seen = initTable[pointer, `Type`]()
        for child in candidate.blocks[0].instrs:
          let original = child.dest
          let copy = cloneInstruction(child, seen)
          substitute(copy, local)
          if original.type != nil:
            if returned.type != nil and returned.kind == ValueKind.Reg and
                returned.name == original.name and instruction.dest.type != nil:
              copy.dest = instruction.dest
            else:
              copy.dest.name = fresh()
            local[original.name] = copy.dest
          retained.add(copy)
        if instruction.dest.type != nil:
          var value = returned
          replace(value, local)
          if value.kind != ValueKind.Reg or value.name != instruction.dest.name:
            replacements[instruction.dest.name] = value
        remaining -= costs[instruction.func]
        inc result
        if connected: inc pipelines
        previous = if instruction.dest.type != nil: instruction.dest.name else: ""
      basicBlock.instrs = retained
      if basicBlock.term != nil: substitute(basicBlock.term, replacements)

proc promoteSlots(function: node.Function): int =
  var owners = initTable[string, string]()
  for basicBlock in function.blocks:
    for instruction in basicBlock.instrs:
      if instruction.kind == InstrKind.Alloc and instruction.op == "slot" and
          instruction.dest.type != nil and instruction.dest.type.kind == TypeKind.Ptr:
        owners[instruction.dest.name] = basicBlock.label
  if owners.len == 0: return

  var valid = initTable[string, bool]()
  var initialized = initTable[string, bool]()
  for name in owners.keys: valid[name] = true
  for basicBlock in function.blocks:
    for instruction in basicBlock.instrs:
      for value in operands(instruction):
        if value.kind != ValueKind.Reg or not owners.hasKey(value.name): continue
        let direct = instruction.ptr.kind == ValueKind.Reg and
          instruction.ptr.name == value.name and
          instruction.kind in {InstrKind.Load, InstrKind.Store}
        if basicBlock.label != owners[value.name] or not direct:
          valid[value.name] = false
        elif instruction.kind == InstrKind.Load and
            not initialized.getOrDefault(value.name):
          valid[value.name] = false
        elif instruction.kind == InstrKind.Store:
          initialized[value.name] = true
    if basicBlock.term != nil:
      for value in operands(basicBlock.term):
        if value.kind == ValueKind.Reg and owners.hasKey(value.name):
          valid[value.name] = false

  for basicBlock in function.blocks:
    var current = initTable[string, Value]()
    var replacements = initTable[string, Value]()
    var retained: seq[Instruction]
    for instruction in basicBlock.instrs:
      substitute(instruction, replacements)
      if instruction.kind == InstrKind.Alloc and instruction.op == "slot" and
          valid.getOrDefault(instruction.dest.name):
        inc result
        continue
      if instruction.ptr.kind == ValueKind.Reg and
          valid.getOrDefault(instruction.ptr.name):
        if instruction.kind == InstrKind.Store:
          current[instruction.ptr.name] = instruction.val
          continue
        if instruction.kind == InstrKind.Load and
            current.hasKey(instruction.ptr.name):
          replacements[instruction.dest.name] = current[instruction.ptr.name]
          continue
      retained.add(instruction)
    basicBlock.instrs = retained
    if basicBlock.term != nil: substitute(basicBlock.term, replacements)

proc eliminateBoundaries(function: node.Function): int =
  for basicBlock in function.blocks:
    var replacements = initTable[string, Value]()
    var retained: seq[Instruction]
    for instruction in basicBlock.instrs:
      substitute(instruction, replacements)
      if instruction.kind == InstrKind.Convert and instruction.dest.type != nil and
          instruction.val.type != nil and
          semanticTypeKey(instruction.dest.type) == semanticTypeKey(instruction.val.type):
        replacements[instruction.dest.name] = instruction.val
        inc result
      else:
        retained.add(instruction)
    basicBlock.instrs = retained
    if basicBlock.term != nil: substitute(basicBlock.term, replacements)

proc specializeContinuations(module: Module): int =
  var specialized = 0
  var blocking = initHashSet[string]()
  for external in module.externs:
    let symbol = if external.symbol.len > 0: external.symbol else: external.name
    if external.abi in ["runtime", "runtime.task"] and symbol == "block" and
        external.params.len == 1 and external.ret != nil and
        external.ret.kind == TypeKind.Void:
      blocking.incl(external.name)
  if blocking.len == 0: return
  for function in module.funcs:
    function.walk(proc(instruction: Instruction) =
      if instruction.kind == InstrKind.Call and instruction.func in blocking and
          instruction.args.len == 1:
        let callback = instruction.args[0]
        if callback.kind == ValueKind.Global and callback.type != nil and
            callback.type.kind == TypeKind.Function and
            callback.type.params.len == 0 and callback.type.ret != nil and
            callback.type.ret.kind == TypeKind.Void:
          instruction.func = callback.name
          instruction.callee = Value()
          instruction.args = @[]
          instruction.abi = callback.type.abi
          instruction.symbol = ""
          instruction.op = "direct-continuation"
          inc specialized)
  result = specialized

proc escape(data: openArray[byte]): seq[byte] =
  result.add(byte('"'))
  for value in data:
    case value
    of byte('"'), byte('\\'):
      result.add(byte('\\')); result.add(value)
    of 8'u8: result.add(@[byte('\\'), byte('b')])
    of 9'u8: result.add(@[byte('\\'), byte('t')])
    of 10'u8: result.add(@[byte('\\'), byte('n')])
    of 12'u8: result.add(@[byte('\\'), byte('f')])
    of 13'u8: result.add(@[byte('\\'), byte('r')])
    else:
      if value < 32:
        const digits = "0123456789abcdef"
        result.add(@[byte('\\'), byte('u'), byte('0'), byte('0'),
          byte(digits[int(value shr 4)]), byte(digits[int(value and 15)])])
      else:
        result.add(value)
  result.add(byte('"'))

proc serialize(module: Module): int =
  var folded = 0
  var quotes = initHashSet[string]()
  for external in module.externs:
    let symbol = if external.symbol.len > 0: external.symbol else: external.name
    if external.abi == "runtime.json" and symbol == "quote":
      quotes.incl(external.name)
  if quotes.len == 0: return
  for function in module.funcs:
    function.walk(proc(instruction: Instruction) =
      if instruction.kind != InstrKind.Call or instruction.func notin quotes or
          instruction.args.len != 1 or instruction.args[0].kind != ValueKind.Const:
        return
      let source = instruction.args[0]
      if source.type == nil or source.type.kind != TypeKind.Slice or
          instruction.dest.type == nil or
          instruction.dest.type.kind != TypeKind.Failable:
        return
      let raw = bytes(source.name)
      var text = newString(raw.len)
      for index, value in raw: text[index] = char(value)
      if text.validateUtf8 != -1: return
      let encoded = escape(raw)
      instruction.kind = InstrKind.Convert
      instruction.val = Value(kind: ValueKind.Const, name: quoted(encoded),
        `type`: instruction.dest.type.elem)
      instruction.args = @[]
      instruction.func = ""
      instruction.symbol = ""
      instruction.abi = ""
      instruction.effects = @[]
      instruction.op = "direct-json"
      inc folded)
  result = folded

proc optimize*(input: Module; options = OptimizeOptions()): OptimizeResult =
  result.module = cloneModule(input)
  let protected = addressTaken(result.module)
  result.continuations = specializeContinuations(result.module)
  result.serializations = serialize(result.module)
  if options.inline:
    result.functions = mergeEquivalent(result.module, protected)
    result.inlined = inlineCalls(result.module, options, protected,
      result.pipelines)
  for function in result.module.funcs:
    result.allocations += promoteSlots(function)
    result.boundaries += eliminateBoundaries(function)
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
  result.module.optimization.expressions += result.expressions
  result.module.optimization.functions += result.functions
  result.module.optimization.dead += result.dead
  result.module.optimization.inlined += result.inlined
  result.module.optimization.boundaries += result.boundaries
  result.module.optimization.allocations += result.allocations
  result.module.optimization.pipelines += result.pipelines
  result.module.optimization.continuations += result.continuations
  result.module.optimization.serializations += result.serializations

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
      inc result.optimization.generics
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
