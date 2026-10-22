import std/[sequtils, sets, strutils, tables]
import ./[kind, node, valid]
import ../opt/arch as architecture
import ../opt/vector as vectorizer
import ../pkg/hash
import std/unicode

type
  Policy* = object
    inline*: bool
    target*: string
    cpu*: string
    backend*: string
    mode*: string
    vectorize*: bool
    hot*: HashSet[string]
  Changes* = object
    module*: Module
    expressions*: int
    functions*: int
    dead*: int
    inlined*: int
    callbacks*: int
    boundaries*: int
    allocations*: int
    pipelines*: int
    continuations*: int
    serializations*: int
    vectors*: int

proc copy(value: `Type`; seen: var Table[pointer, `Type`]): `Type` =
  if value == nil: return nil
  let identity = cast[pointer](value)
  if seen.hasKey(identity): return seen[identity]
  result = `Type`(kind: value.kind, name: value.name, width: value.width,
    abi: value.abi, attributes: value.attributes, volatile: value.volatile,
    constant: value.constant, fields: initOrderedTable[string, `Type`](),
    annotations: value.annotations, variants: initOrderedTable[string, `Type`]())
  seen[identity] = result
  result.elem = copy(value.elem, seen)
  for parameter in value.params: result.params.add(copy(parameter, seen))
  result.ret = copy(value.ret, seen)
  for name, field in value.fields: result.fields[name] = copy(field, seen)
  for name, variant in value.variants: result.variants[name] = copy(variant, seen)

proc copy(value: Value; seen: var Table[pointer, `Type`]): Value =
  Value(kind: value.kind, name: value.name, bits: value.bits,
    `type`: copy(value.type, seen))

proc copy(value: Instruction; seen: var Table[pointer, `Type`]): Instruction
proc copy(value: Block; seen: var Table[pointer, `Type`]): Block =
  if value == nil: return nil
  result = Block(label: value.label)
  for parameter in value.params: result.params.add(copy(parameter, seen))
  for instruction in value.instrs: result.instrs.add(copy(instruction, seen))
  result.term = copy(value.term, seen)

proc copy(value: Instruction; seen: var Table[pointer, `Type`]): Instruction =
  if value == nil: return nil
  result = Instruction(kind: value.kind, memory: value.memory, op: value.op,
    field: value.field, panic: value.panic, trace: value.trace,
    effects: value.effects, span: value.span, error: value.error,
    symbol: value.symbol, region: value.region, `func`: value.func,
    abi: value.abi, attributes: value.attributes, label: value.label,
    yes: value.yes, no: value.no, msg: value.msg,
    handler: value.handler, path: value.path, evaluation: value.evaluation,
    mask: value.mask, reduction: value.reduction, code: value.code)
  result.dest = copy(value.dest, seen); result.target = copy(value.target, seen)
  result.ptr = copy(value.ptr, seen); result.val = copy(value.val, seen)
  result.val2 = copy(value.val2, seen); result.callee = copy(value.callee, seen)
  result.cond = copy(value.cond, seen); result.value = copy(value.value, seen)
  result.expr = copy(value.expr, seen)
  for item in value.args: result.args.add(copy(item, seen))
  for item in value.positive: result.positive.add(copy(item, seen))
  for item in value.negative: result.negative.add(copy(item, seen))
  for edge in value.blocks: result.blocks.add((label: edge.label, value: copy(edge.value, seen)))
  result.fallback = copy(value.fallback, seen)
  for section in value.fallbackBlocks:
    result.fallbackBlocks.add(copy(section, seen))
  result.argument = copy(value.argument, seen)
  for item in value.arguments: result.arguments.add(copy(item, seen))

proc copy(value: node.Function; seen: var Table[pointer, `Type`]): node.Function =
  result = node.Function(public: value.public, line: value.line, name: value.name,
    abi: value.abi, attributes: value.attributes, generics: value.generics,
    ret: copy(value.ret, seen), derives: value.derives)
  for parameter in value.params: result.params.add(copy(parameter, seen))
  for section in value.blocks: result.blocks.add(copy(section, seen))

proc copy*(input: Module): Module =
  var seen = initTable[pointer, `Type`]()
  result = Module(version: input.version, stage: input.stage, name: input.name,
    inputs: input.inputs,
    package: input.package, path: input.path, target: input.target,
    requires: input.requires, regions: input.regions, traces: input.traces,
    native: input.native, residue: input.residue,
    optimization: input.optimization)
  for item in input.storage:
    result.storage.add(Storage(name: item.name, public: item.public,
      thread: item.thread, alignment: item.alignment,
      section: item.section, value: copy(item.value, seen)))
  for item in input.types:
    result.types.add(Definition(name: item.name, `type`: copy(item.type, seen)))
  for item in input.externs:
    var copy = Extern(generics: item.generics, symbol: item.symbol,
      name: item.name, abi: item.abi, ret: copy(item.ret, seen))
    for parameter in item.params: copy.params.add(copy(parameter, seen))
    result.externs.add(copy)
  for function in input.funcs: result.funcs.add(copy(function, seen))

proc walk(function: node.Function; visit: proc(instruction: Instruction) {.closure.}) =
  var pending = function.blocks
  var index = 0
  while index < pending.len:
    let section = pending[index]; inc index
    for instruction in section.instrs:
      visit(instruction)
      if instruction.fallback != nil: pending.add(instruction.fallback)
      pending.add(instruction.fallbackBlocks)
    if section.term != nil:
      visit(section.term)
      if section.term.fallback != nil: pending.add(section.term.fallback)
      pending.add(section.term.fallbackBlocks)

proc prepare*(input: Module): Module =
  result = copy(input)
  for function in result.funcs:
    var normal = initHashSet[string]()
    var exceptional = initHashSet[string]()
    if function.blocks.len > 0: normal.incl(function.blocks[0].label)
    for section in function.blocks:
      if section.term != nil:
        if section.term.label.len > 0: normal.incl(section.term.label)
        if section.term.yes.len > 0: normal.incl(section.term.yes)
        if section.term.no.len > 0: normal.incl(section.term.no)
      for instruction in section.instrs:
        if instruction.panic.len > 0: exceptional.incl(instruction.panic)
        if instruction.kind == Opcode.Thread and instruction.func.len > 0:
          instruction.kind = Opcode.Call
    var retained: seq[Block]
    for section in function.blocks:
      if section.label in normal or section.label notin exceptional:
        retained.add(section)
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
  result.add(instruction.positive)
  result.add(instruction.negative)
  for edge in instruction.blocks: result.add(edge.value)

proc replace(value: var Value; replacements: Table[string, Value]) =
  var seen = initHashSet[string]()
  while value.kind == Flavor.Reg and replacements.hasKey(value.name) and value.name notin seen:
    seen.incl(value.name)
    value = replacements[value.name]

proc substitute(instruction: Instruction; replacements: Table[string, Value]) =
  replace(instruction.val, replacements); replace(instruction.val2, replacements)
  replace(instruction.ptr, replacements); replace(instruction.target, replacements)
  replace(instruction.callee, replacements); replace(instruction.cond, replacements)
  replace(instruction.value, replacements); replace(instruction.expr, replacements)
  for value in instruction.args.mitems: replace(value, replacements)
  for value in instruction.positive.mitems: replace(value, replacements)
  for value in instruction.negative.mitems: replace(value, replacements)
  for edge in instruction.blocks.mitems: replace(edge.value, replacements)
  if instruction.fallback != nil:
    for child in instruction.fallback.instrs: substitute(child, replacements)
    if instruction.fallback.term != nil: substitute(instruction.fallback.term, replacements)
  for section in instruction.fallbackBlocks:
    for child in section.instrs: substitute(child, replacements)
    if section.term != nil: substitute(section.term, replacements)

proc pure(instruction: Instruction): bool =
  if instruction == nil or instruction.dest.name.len == 0 or instruction.effects.len > 0 or
      instruction.panic.len > 0 or instruction.trace.len > 0 or
      instruction.memory.input.len > 0 or instruction.fallback != nil or
      instruction.fallbackBlocks.len > 0: return false
  if instruction.kind in {Opcode.Add, Opcode.Sub, Opcode.Mul,
      Opcode.Div, Opcode.Remainder}:
    return instruction.dest.type != nil and instruction.dest.type.kind == Shape.Float
  if instruction.kind == Opcode.Reduce:
    return instruction.dest.type != nil and instruction.dest.type.kind == Shape.Float
  if instruction.kind == Opcode.Construct:
    return instruction.dest.type != nil and instruction.dest.type.kind != Shape.Slice
  if instruction.kind == Opcode.Bit:
    return instruction.op in ["and", "or", "xor", "not"]
  instruction.kind in {Opcode.Not, Opcode.Convert, Opcode.Compare,
    Opcode.Length, Opcode.Splat, Opcode.Shuffle, Opcode.Select}

proc signature(value: `Type`; active: var HashSet[pointer]): string =
  if value == nil: return "nil"
  let identity = cast[pointer](value)
  if identity in active: return "ref(" & value.name & ")"
  active.incl(identity)
  result = $value.kind & "(" & $value.name.len & ":" & value.name & "," &
    $value.width & "," & $value.constant & "," & $value.volatile & "," &
    $value.abi.len & ":" & value.abi
  for attribute in value.attributes:
    result.add(",a" & $attribute.len & ":" & attribute)
  if value.elem != nil: result.add(",e" & signature(value.elem, active))
  for parameter in value.params:
    result.add(",p" & signature(parameter, active))
  if value.ret != nil: result.add(",r" & signature(value.ret, active))
  for name, member in value.fields:
    result.add(",f" & $name.len & ":" & name & "=" &
      signature(member, active))
    for attribute in value.annotations.getOrDefault(name):
      result.add("#" & $attribute.len & ":" & attribute)
  for name, variantType in value.variants:
    result.add(",v" & $name.len & ":" & name & "=" &
      signature(variantType, active))
  result.add(")")
  active.excl(identity)

proc signature(value: `Type`): string =
  var active = initHashSet[pointer]()
  signature(value, active)

proc key(value: Value): string =
  $value.kind & ":" & $value.name.len & ":" & value.name & ":" &
    $value.bits.len & ":" & value.bits & ":" & signature(value.type)
proc key(instruction: Instruction): string =
  result = $instruction.kind & ":" & instruction.op & ":" &
    instruction.field & ":" & instruction.reduction
  for item in instruction.mask: result.add("#" & $item)
  for value in operands(instruction): result.add("|" & key(value))
  if instruction.dest.type != nil:
    result.add("->" & signature(instruction.dest.type))

proc pure*(function: node.Function): bool =
  ## Shared conservative proof for boundary elimination and backend metadata.
  ## Absence of a proof must never be interpreted as absence of effects.
  if function == nil or function.public or function.name == "main" or
      function.abi.len > 0 or function.attributes.len > 0 or
      function.blocks.len != 1 or function.ret == nil or
      function.ret.kind in {Shape.Error, Shape.Failable}: return false
  let section = function.blocks[0]
  if section == nil or section.term == nil or
      section.term.kind != Opcode.Return: return false
  for parameter in section.params:
    if parameter.type == nil or parameter.type.kind != Shape.Memory: return false
  for instruction in section.instrs:
    if not pure(instruction): return false
    for value in operands(instruction):
      if value.kind == Flavor.Global: return false
  section.term.value.type == nil or section.term.value.kind != Flavor.Global

proc canonical(value: Value; names: Table[string, string]): string =
  if value.type == nil: return "none"
  let identity = case value.kind
    of Flavor.Reg: names.getOrDefault(value.name, "?" & value.name)
    of Flavor.Const: value.name & ":" & value.bits
    of Flavor.Global: value.name
  $value.kind & ":" & $identity.len & ":" & identity & ":" &
    signature(value.type)

proc fingerprint(function: node.Function): string =
  var names = initTable[string, string]()
  result = "ret=" & signature(function.ret)
  for index, parameter in function.params:
    names[parameter.name] = "p" & $index
    result.add("|param=" & signature(parameter.type))
  var serial = 0
  for instruction in function.blocks[0].instrs:
    result.add("|op=" & $instruction.kind & ":" & instruction.op & ":" &
      instruction.field & ":" & instruction.reduction)
    for item in instruction.mask: result.add("#" & $item)
    for value in operands(instruction):
      result.add(";" & canonical(value, names))
    result.add("->" & signature(instruction.dest.type))
    names[instruction.dest.name] = "v" & $serial
    inc serial
  result.add("|return=" & canonical(function.blocks[0].term.value, names))

proc addresses(module: Module): HashSet[string] =
  var taken = initHashSet[string]()
  for function in module.funcs:
    function.walk(proc(instruction: Instruction) =
      for value in operands(instruction):
        if value.kind == Flavor.Global and value.type != nil and
            value.type.kind == Shape.Function:
          taken.incl(value.name))
  taken

proc specializeCallbacks(module: Module): int =
  var functions = initTable[string, node.Function]()
  var occupied = initHashSet[string]()
  for function in module.funcs:
    functions[function.name] = function
    occupied.incl(function.name)
  for external in module.externs: occupied.incl(external.name)
  var instances = initTable[tuple[callee: string, position: int,
    callback: string], string]()
  var usedTraces = initHashSet[string]()
  for trace in module.traces: usedTraces.incl(trace.id)
  var clones: seq[node.Function]
  var traces: seq[Trace]
  var specialized = 0
  var remaining = 4096
  for caller in module.funcs:
    caller.walk(proc(call: Instruction) =
      if call.kind != Opcode.Call or not functions.hasKey(call.func): return
      let original = functions[call.func]
      if original.abi.len > 0 or original.attributes.len > 0 or
          original.params.len != call.args.len: return
      for index, argument in call.args:
        if argument.kind != Flavor.Global or argument.type == nil or
            argument.type.kind != Shape.Function or
            original.params[index].type == nil or
            signature(original.params[index].type) != signature(argument.type) or
            not functions.hasKey(argument.name): continue
        let callback = functions[argument.name]
        if callback.abi != argument.type.abi or
            callback.params.len != argument.type.params.len or
            signature(callback.ret) != signature(argument.type.ret): continue
        var compatible = true
        for position, parameter in callback.params:
          if signature(parameter.type) != signature(argument.type.params[position]):
            compatible = false
            break
        if not compatible: continue
        let parameter = original.params[index].name
        var present = false
        original.walk(proc(instruction: Instruction) =
          if instruction.kind == Opcode.Call and instruction.callee.kind == Flavor.Reg and
              instruction.callee.name == parameter: present = true)
        if not present: continue
        var weight = 0
        original.walk(proc(instruction: Instruction) = inc weight)
        if weight > 512 or weight > remaining: continue
        let key = (callee: original.name, position: index,
          callback: argument.name)
        if not instances.hasKey(key):
          if clones.len >= 128: continue
          let base = original.name & "__callback_" &
            digest(original.name & ":" & $index & ":" & argument.name)[0..<16]
          var name = base
          var serial = 0
          while name in occupied:
            inc serial
            name = base & "_" & $serial
          occupied.incl(name)
          var seen = initTable[pointer, `Type`]()
          let clone = copy(original, seen)
          clone.name = name
          clone.public = false
          var slots = initTable[string, string]()
          var position = 0
          for trace in module.traces:
            if trace.`function` == original.name:
              var id = name & ".trace." & $position
              while id in usedTraces:
                inc position
                id = name & ".trace." & $position
              usedTraces.incl(id)
              inc position
              slots[trace.id] = id
              traces.add(Trace(id: id, `function`: name))
          clone.walk(proc(instruction: Instruction) =
            if slots.hasKey(instruction.trace):
              instruction.trace = slots[instruction.trace]
            if instruction.kind == Opcode.Call and instruction.callee.kind == Flavor.Reg and
                instruction.callee.name == parameter:
              instruction.func = argument.name
              instruction.callee = Value()
              instruction.symbol = "")
          clones.add(clone)
          instances[key] = name
          inc specialized
          remaining -= weight
        call.func = instances[key]
        break)
  module.funcs.add(clones)
  module.traces.add(traces)
  result = specialized

proc merge(module: Module; protected: HashSet[string]): int =
  var representatives = initTable[string, string]()
  var aliases = initTable[string, string]()
  var retained: seq[node.Function]
  for function in module.funcs:
    if pure(function) and function.name notin protected:
      let key = fingerprint(function)
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

proc cost(instruction: Instruction; profile: architecture.Profile): int =
  case instruction.kind
  of Opcode.Mul: profile.multiply
  of Opcode.Div, Opcode.Remainder: profile.divide
  of Opcode.Construct: 4
  of Opcode.Splat, Opcode.Shuffle, Opcode.Select, Opcode.Reduce: 2
  else: 1

proc cost(function: node.Function; profile: architecture.Profile): int =
  for instruction in function.blocks[0].instrs:
    result += cost(instruction, profile)

proc guardedInlineable(function: node.Function): bool =
  if function == nil or function.public or function.name == "main" or
      function.abi.len > 0 or function.attributes.len > 0 or
      function.blocks.len < 2 or function.ret == nil or
      function.ret.kind in {Shape.Error, Shape.Failable}:
    return false
  let entry = function.blocks[0]
  if entry == nil or entry.term == nil or entry.term.kind != Opcode.Return or
      entry.params.len != 1 or entry.params[0].type == nil or
      entry.params[0].type.kind != Shape.Memory or
      entry.term.memory.input != entry.params[0].name:
    return false
  var failures = initHashSet[string]()
  for section in function.blocks[1 .. ^1]:
    if section == nil or section.term == nil or
        section.term.kind != Opcode.Panic or section.instrs.len > 0 or
        section.params.len != 1 or section.params[0].type == nil or
        section.params[0].type.kind != Shape.Memory or
        section.term.memory.input != section.params[0].name:
      return false
    failures.incl(section.label)
  var used = initHashSet[string]()
  for instruction in entry.instrs:
    if instruction.memory.output.len > 0: return false
    let checked = instruction.kind in {Opcode.Add, Opcode.Sub, Opcode.Mul} and
      instruction.dest.type != nil and
      instruction.dest.type.kind in {Shape.Int, Shape.Uint} and
      instruction.panic in failures and instruction.effects.len == 0 and
      instruction.trace.len == 0 and instruction.memory.input.len == 0 and
      instruction.fallback == nil and instruction.fallbackBlocks.len == 0
    if not (pure(instruction) or checked): return false
    if checked: used.incl(instruction.panic)
    for value in operands(instruction):
      if value.kind == Flavor.Global: return false
  used.len == failures.len and
    entry.term.value.type != nil and entry.term.value.kind != Flavor.Global

proc inline(module: Module; options: Policy;
    protected: HashSet[string]; pipelines: var int): int =
  let profile = architecture.profile(options.target, options.cpu)
  let budget = max(1, profile.budget)
  let maximum = max(4, budget div 4)
  var candidates = initTable[string, node.Function]()
  var costs = initTable[string, int]()
  var guarded = initHashSet[string]()
  for function in module.funcs:
    let checked = options.backend == "qbe" and options.mode == "release" and
      options.target in ["x86_64-linux-gnu", "x86_64-windows-msvc"] and
      guardedInlineable(function)
    if (pure(function) or checked) and function.name notin protected:
      let weight = cost(function, profile)
      let limit = if function.name in options.hot: maximum * 2 else: maximum
      if weight <= limit:
        candidates[function.name] = function
        costs[function.name] = weight
        if checked: guarded.incl(function.name)
  for caller in module.funcs:
    var remaining = if caller.name in options.hot: budget * 2 else: budget
    var serial = 0
    var occupied = initHashSet[string]()
    for parameter in caller.params: occupied.incl(parameter.name)
    for section in caller.blocks:
      occupied.incl(section.label)
      for parameter in section.params: occupied.incl(parameter.name)
      for instruction in section.instrs:
        if instruction.dest.name.len > 0: occupied.incl(instruction.dest.name)
    proc fresh(): string =
      while true:
        inc serial
        result = "inlined_" & $serial
        if result notin occupied:
          occupied.incl(result)
          return
    var replacements = initTable[string, Value]()
    var memoryAliases = initTable[string, string]()
    var extraBlocks: seq[Block]
    for section in caller.blocks:
      var retained: seq[Instruction]
      var previous = ""
      for instruction in section.instrs:
        let connected = previous.len > 0 and instruction.kind == Opcode.Call and
          instruction.args.anyIt(it.kind == Flavor.Reg and it.name == previous)
        substitute(instruction, replacements)
        if memoryAliases.hasKey(instruction.memory.input):
          instruction.memory.input = memoryAliases[instruction.memory.input]
        if instruction.kind != Opcode.Call or
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
        var panicLabels = initTable[string, string]()
        if instruction.func in guarded:
          for failure in candidate.blocks[1 .. ^1]:
            let cloned = copy(failure, seen)
            cloned.label = fresh()
            panicLabels[failure.label] = cloned.label
            let memory = fresh()
            cloned.params[0].name = memory
            cloned.term.memory.input = memory
            extraBlocks.add(cloned)
        for child in candidate.blocks[0].instrs:
          let original = child.dest
          let copy = copy(child, seen)
          substitute(copy, local)
          if copy.panic.len > 0 and panicLabels.hasKey(copy.panic):
            copy.panic = panicLabels[copy.panic]
          if original.type != nil:
            if returned.type != nil and returned.kind == Flavor.Reg and
                returned.name == original.name and instruction.dest.type != nil:
              copy.dest = instruction.dest
            else:
              copy.dest.name = fresh()
            local[original.name] = copy.dest
          retained.add(copy)
        if instruction.dest.type != nil:
          var value = returned
          replace(value, local)
          if value.kind != Flavor.Reg or value.name != instruction.dest.name:
            replacements[instruction.dest.name] = value
        if instruction.func in guarded and instruction.memory.output.len > 0:
          memoryAliases[instruction.memory.output] = instruction.memory.input
          replacements[instruction.memory.output] = Value(kind: Flavor.Reg,
            name: instruction.memory.input, `type`: `Type`(kind: Shape.Memory))
        remaining -= costs[instruction.func]
        inc result
        if connected: inc pipelines
        previous = if instruction.dest.type != nil: instruction.dest.name else: ""
      section.instrs = retained
      if section.term != nil:
        substitute(section.term, replacements)
        if memoryAliases.hasKey(section.term.memory.input):
          section.term.memory.input = memoryAliases[section.term.memory.input]
    caller.blocks.add(extraBlocks)

proc promote(function: node.Function): int =
  var owners = initTable[string, string]()
  for section in function.blocks:
    for instruction in section.instrs:
      if instruction.kind == Opcode.Alloc and instruction.op == "slot" and
          instruction.dest.type != nil and instruction.dest.type.kind == Shape.Ptr:
        if instruction.dest.type.elem != nil and not instruction.dest.type.volatile and
            not instruction.dest.type.elem.volatile and instruction.effects.len == 0 and
            instruction.panic.len == 0 and instruction.trace.len == 0 and
            instruction.fallback == nil and instruction.fallbackBlocks.len == 0:
          owners[instruction.dest.name] = section.label
  if owners.len == 0: return

  var valid = initTable[string, bool]()
  var initialized = initTable[string, bool]()
  for name in owners.keys: valid[name] = true
  for section in function.blocks:
    for instruction in section.instrs:
      for value in operands(instruction):
        if value.kind != Flavor.Reg or not owners.hasKey(value.name): continue
        let direct = instruction.ptr.kind == Flavor.Reg and
          instruction.ptr.name == value.name and
          instruction.kind in {Opcode.Load, Opcode.Store}
        if section.label != owners[value.name] or not direct or
            instruction.effects.len > 0 or instruction.panic.len > 0 or
            instruction.trace.len > 0 or instruction.fallback != nil or
            instruction.fallbackBlocks.len > 0 or
            value.type == nil or value.type.elem == nil or
            value.type.volatile or value.type.elem.volatile:
          valid[value.name] = false
        elif instruction.kind == Opcode.Load and
            not initialized.getOrDefault(value.name):
          valid[value.name] = false
        elif instruction.kind == Opcode.Store:
          initialized[value.name] = true
    if section.term != nil:
      for value in operands(section.term):
        if value.kind == Flavor.Reg and owners.hasKey(value.name):
          valid[value.name] = false

  for section in function.blocks:
    var current = initTable[string, Value]()
    var replacements = initTable[string, Value]()
    var retained: seq[Instruction]
    for instruction in section.instrs:
      substitute(instruction, replacements)
      if instruction.kind == Opcode.Alloc and instruction.op == "slot" and
          valid.getOrDefault(instruction.dest.name):
        inc result
        continue
      if instruction.ptr.kind == Flavor.Reg and
          valid.getOrDefault(instruction.ptr.name):
        if instruction.kind == Opcode.Store:
          current[instruction.ptr.name] = instruction.val
          continue
        if instruction.kind == Opcode.Load and
            current.hasKey(instruction.ptr.name):
          replacements[instruction.dest.name] = current[instruction.ptr.name]
          continue
      retained.add(instruction)
    section.instrs = retained
    if section.term != nil: substitute(section.term, replacements)

proc eliminate(function: node.Function): int =
  for section in function.blocks:
    var replacements = initTable[string, Value]()
    var retained: seq[Instruction]
    for instruction in section.instrs:
      substitute(instruction, replacements)
      if instruction.kind == Opcode.Convert and pure(instruction) and instruction.dest.type != nil and
          instruction.val.type != nil and
          signature(instruction.dest.type) == signature(instruction.val.type):
        replacements[instruction.dest.name] = instruction.val
        inc result
      else:
        retained.add(instruction)
    section.instrs = retained
    if section.term != nil: substitute(section.term, replacements)

proc continuations(module: Module): int =
  var specialized = 0
  var blocking = initHashSet[string]()
  for external in module.externs:
    let symbol = if external.symbol.len > 0: external.symbol else: external.name
    if external.abi in ["runtime", "runtime.task"] and symbol == "block" and
        external.params.len == 1 and external.ret != nil and
        external.ret.kind == Shape.Void:
      blocking.incl(external.name)
  if blocking.len == 0: return
  for function in module.funcs:
    function.walk(proc(instruction: Instruction) =
      if instruction.kind == Opcode.Call and instruction.func in blocking and
          instruction.args.len == 1:
        let callback = instruction.args[0]
        if callback.kind == Flavor.Global and callback.type != nil and
            callback.type.kind == Shape.Function and
            callback.type.params.len == 0 and callback.type.ret != nil and
            callback.type.ret.kind == Shape.Void:
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
      if instruction.kind != Opcode.Call or instruction.func notin quotes or
          instruction.args.len != 1 or instruction.args[0].kind != Flavor.Const:
        return
      let source = instruction.args[0]
      if source.type == nil or source.type.kind != Shape.Slice or
          instruction.dest.type == nil or
          instruction.dest.type.kind != Shape.Failable:
        return
      let raw = bytes(source.name)
      var text = newString(raw.len)
      for index, value in raw: text[index] = char(value)
      if text.validateUtf8 != -1: return
      let encoded = escape(raw)
      instruction.kind = Opcode.Convert
      instruction.val = Value(kind: Flavor.Const, name: quoted(encoded),
        `type`: instruction.dest.type.elem)
      instruction.args = @[]
      instruction.func = ""
      instruction.symbol = ""
      instruction.abi = ""
      instruction.effects = @[]
      instruction.op = "direct-json"
      inc folded)
  result = folded

proc optimize*(input: Module; options = Policy()): Changes =
  result.module = copy(input)
  if options.vectorize:
    result.vectors = vectorizer.apply(result.module, options.backend,
      options.target, options.cpu, options.mode)
  let protected = addresses(result.module)
  result.continuations = continuations(result.module)
  result.serializations = serialize(result.module)
  if options.inline:
    result.callbacks = specializeCallbacks(result.module)
    result.functions = merge(result.module, protected)
    result.inlined = inline(result.module, options, protected,
      result.pipelines)
  for function in result.module.funcs:
    result.allocations += promote(function)
    result.boundaries += eliminate(function)
    var replacements = initTable[string, Value]()
    for section in function.blocks:
      var seen = initTable[string, Value]()
      var retained: seq[Instruction]
      for instruction in section.instrs:
        substitute(instruction, replacements)
        if pure(instruction):
          let key = key(instruction)
          if seen.hasKey(key):
            replacements[instruction.dest.name] = seen[key]
            inc result.expressions
            continue
          seen[key] = instruction.dest
        else:
          seen.clear()
        retained.add(instruction)
      section.instrs = retained
      if section.term != nil: substitute(section.term, replacements)
    var changed = true
    while changed:
      changed = false
      var used = initHashSet[string]()
      for section in function.blocks:
        for instruction in section.instrs:
          for value in operands(instruction):
            if value.kind == Flavor.Reg: used.incl(value.name)
        if section.term != nil:
          for value in operands(section.term):
            if value.kind == Flavor.Reg: used.incl(value.name)
      for section in function.blocks:
        var retained: seq[Instruction]
        for instruction in section.instrs:
          if pure(instruction) and instruction.dest.name notin used:
            inc result.dead; changed = true
          else: retained.add(instruction)
        section.instrs = retained
  if result.module.version == 1:
    discard seal(result.module)
  result.module.optimization.expressions += result.expressions
  result.module.optimization.functions += result.functions
  result.module.optimization.dead += result.dead
  result.module.optimization.inlined += result.inlined
  result.module.optimization.callbacks += result.callbacks
  result.module.optimization.boundaries += result.boundaries
  result.module.optimization.allocations += result.allocations
  result.module.optimization.pipelines += result.pipelines
  result.module.optimization.continuations += result.continuations
  result.module.optimization.serializations += result.serializations
  result.module.optimization.vectors += result.vectors

proc key(value: `Type`): string =
  if value == nil: return "void"
  $value.kind & "_" & digest(signature(value))

proc substitute(value: `Type`; bindings: Table[string, `Type`];
    seen: var Table[pointer, `Type`]): `Type` =
  if value == nil: return nil
  if value.kind == Shape.Struct and bindings.hasKey(value.name): return bindings[value.name]
  let identity = cast[pointer](value)
  if seen.hasKey(identity): return seen[identity]
  result = `Type`(kind: value.kind, name: value.name, width: value.width,
    abi: value.abi, attributes: value.attributes, volatile: value.volatile,
    constant: value.constant, fields: initOrderedTable[string, `Type`](),
    annotations: value.annotations, variants: initOrderedTable[string, `Type`]())
  seen[identity] = result
  result.elem = substitute(value.elem, bindings, seen)
  for parameter in value.params: result.params.add(substitute(parameter, bindings, seen))
  result.ret = substitute(value.ret, bindings, seen)
  for name, field in value.fields: result.fields[name] = substitute(field, bindings, seen)
  for name, variant in value.variants: result.variants[name] = substitute(variant, bindings, seen)

proc specialize(value: var Value; bindings: Table[string, `Type`];
    seen: var Table[pointer, `Type`]) =
  value.type = substitute(value.type, bindings, seen)

proc specialize(function: node.Function; bindings: Table[string, `Type`]) =
  var seen = initTable[pointer, `Type`]()
  for parameter in function.params.mitems: specialize(parameter, bindings, seen)
  function.ret = substitute(function.ret, bindings, seen)
  function.generics = @[]
  function.walk(proc(instruction: Instruction) =
    specialize(instruction.dest, bindings, seen)
    specialize(instruction.val, bindings, seen)
    specialize(instruction.val2, bindings, seen)
    specialize(instruction.ptr, bindings, seen)
    specialize(instruction.target, bindings, seen)
    specialize(instruction.callee, bindings, seen)
    specialize(instruction.cond, bindings, seen)
    specialize(instruction.value, bindings, seen)
    specialize(instruction.expr, bindings, seen)
    for value in instruction.args.mitems: specialize(value, bindings, seen)
    for value in instruction.positive.mitems: specialize(value, bindings, seen)
    for value in instruction.negative.mitems: specialize(value, bindings, seen)
    for edge in instruction.blocks.mitems: specialize(edge.value, bindings, seen)
    instruction.argument = substitute(instruction.argument, bindings, seen)
    for typ in instruction.arguments.mitems: typ = substitute(typ, bindings, seen))
  var sections = function.blocks
  var position = 0
  while position < sections.len:
    let section = sections[position]
    inc position
    for parameter in section.params.mitems:
      specialize(parameter, bindings, seen)
    for instruction in section.instrs:
      if instruction.fallback != nil: sections.add(instruction.fallback)
      sections.add(instruction.fallbackBlocks)
    if section.term != nil and section.term.fallback != nil:
      sections.add(section.term.fallback)
    if section.term != nil: sections.add(section.term.fallbackBlocks)

proc monomorphize*(input: Module): Module =
  result = copy(input)
  var routines = initTable[string, node.Function]()
  var externals = initTable[string, Extern]()
  var functions: seq[node.Function]
  for function in result.funcs:
    if function.generics.len > 0: routines[function.name] = function
    else: functions.add(function)
  var externs: seq[Extern]
  for external in result.externs:
    if external.generics.len > 0: externals[external.name] = external
    else: externs.add(external)
  proc generic(name: string): bool =
    routines.hasKey(name) or externals.hasKey(name)
  var instances = initTable[string, string]()
  var instantiations: seq[Trace]
  var queue: seq[Instruction]
  for function in functions:
    function.walk(proc(instruction: Instruction) =
      if instruction.kind == Opcode.Call and generic(instruction.func):
        queue.add(instruction))
  var position = 0
  while position < queue.len:
    let call = queue[position]; inc position
    let spelling = call.func
    let parameters = if routines.hasKey(spelling):
      routines[spelling].generics
      else: externals[spelling].generics
    if call.arguments.len != parameters.len:
      raise newException(ValueError, "Generic function '" & spelling &
        "' needs " & $parameters.len & " type arguments")
    var key = spelling
    for typ in call.arguments: key.add("_" & key(typ))
    if not instances.hasKey(key):
      if instances.len >= 4096:
        raise newException(ValueError,
          "Generic specialization exceeds 4096 instances; check for expanding recursive type arguments")
      var bindings = initTable[string, `Type`]()
      for index, parameter in parameters: bindings[parameter] = call.arguments[index]
      let identifier = key
      instances[key] = identifier
      inc result.optimization.generics
      if externals.hasKey(spelling):
        let original = externals[spelling]
        var seen = initTable[pointer, `Type`]()
        var clone = Extern(name: identifier,
          symbol: if original.symbol.len > 0: original.symbol else: original.name,
          abi: original.abi,
          ret: substitute(original.ret, bindings, seen))
        for parameter in original.params:
          clone.params.add(substitute(parameter, bindings, seen))
        externs.add(clone)
      else:
        let original = routines[spelling]
        var copied = initTable[pointer, `Type`]()
        var clone = copy(original, copied)
        clone.name = identifier
        specialize(clone, bindings)
        functions.add(clone)
        clone.walk(proc(instruction: Instruction) =
          if instruction.trace.len > 0:
            let suffix = if instruction.trace.startsWith(spelling):
              instruction.trace[spelling.len .. ^1]
            else: ".trace"
            instruction.trace = identifier & suffix
            if not instantiations.anyIt(it.id == instruction.trace):
              instantiations.add(Trace(id: instruction.trace,
                `function`: identifier))
          if instruction.kind == Opcode.Call and generic(instruction.func):
            queue.add(instruction))
    call.func = instances[key]
    call.arguments = @[]
  result.funcs = functions
  result.externs = externs
  var labels = initHashSet[string]()
  for name in routines.keys: labels.incl(name)
  for name in externals.keys: labels.incl(name)
  var traces: seq[Trace]
  for trace in result.traces:
    if trace.function notin labels: traces.add(trace)
  traces.add(instantiations)
  result.traces = traces

  var visited = initHashSet[pointer]()
  var declarations = initOrderedTable[string, Definition]()
  for declaration in result.types: declarations[declaration.name] = declaration
  proc instantiate(value: `Type`) =
    if value == nil: return
    let identity = cast[pointer](value)
    if identity in visited: return
    visited.incl(identity)
    instantiate(value.elem)
    for parameter in value.params: instantiate(parameter)
    instantiate(value.ret)
    for field in value.fields.values: instantiate(field)
    for variant in value.variants.values: instantiate(variant)
    let bracket = value.name.find('[')
    if value.kind in {Shape.Struct, Shape.PackedStruct,
        Shape.TaggedUnion} and bracket >= 0 and value.params.len > 0:
      var suffix: seq[string]
      for parameter in value.params: suffix.add(key(parameter))
      value.name = value.name[0 ..< bracket] & "__" & suffix.join("__")
      declarations[value.name] = Definition(name: value.name, `type`: value)
  proc instantiate(value: var Value) = instantiate(value.type)
  proc instantiate(instruction: Instruction) =
    if instruction == nil: return
    instantiate(instruction.dest); instantiate(instruction.val)
    instantiate(instruction.val2); instantiate(instruction.ptr)
    instantiate(instruction.target); instantiate(instruction.callee)
    instantiate(instruction.cond); instantiate(instruction.value)
    instantiate(instruction.expr)
    for value in instruction.args.mitems: instantiate(value)
    for value in instruction.positive.mitems: instantiate(value)
    for value in instruction.negative.mitems: instantiate(value)
    for edge in instruction.blocks.mitems: instantiate(edge.value)
    instantiate(instruction.argument)
    for value in instruction.arguments: instantiate(value)
    if instruction.fallback != nil:
      for parameter in instruction.fallback.params.mitems: instantiate(parameter)
      for child in instruction.fallback.instrs: instantiate(child)
      instantiate(instruction.fallback.term)
    for section in instruction.fallbackBlocks:
      for parameter in section.params.mitems: instantiate(parameter)
      for child in section.instrs: instantiate(child)
      instantiate(section.term)
  for declaration in result.types: instantiate(declaration.type)
  for item in result.storage.mitems: instantiate(item.value)
  for external in result.externs.mitems:
    for parameter in external.params: instantiate(parameter)
    instantiate(external.ret)
  for function in result.funcs:
    for parameter in function.params.mitems: instantiate(parameter)
    instantiate(function.ret)
    for section in function.blocks:
      for parameter in section.params.mitems: instantiate(parameter)
      for instruction in section.instrs: instantiate(instruction)
      instantiate(section.term)
  result.types = @[]
  for declaration in declarations.values: result.types.add(declaration)
