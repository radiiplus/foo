import std/[sequtils, sets, tables]
import ./[kind, monomorph, node]

proc reach*(input: Module; library = false): Module =
  result = copy(input)
  var functions = initTable[string, node.Function]()
  var stores = initTable[string, Storage]()
  var externs = initHashSet[string]()
  var storage = initHashSet[string]()
  for fn in result.funcs: functions[fn.name] = fn
  for declaration in result.externs: externs.incl(declaration.name)
  for item in result.storage:
    storage.incl(item.name)
    stores[item.name] = item

  var pending: seq[string]
  var roots = initHashSet[string]()
  for fn in result.funcs:
    if fn.name == "main" or "start" in fn.attributes or
        fn.attributes.anyIt(it in ["interrupt", "interrupt_error_code",
          "interrupt_el2", "interrupt_el3"]) or
        (fn.abi.len > 0 and fn.abi != "gpu") or
        (library and fn.public):
      roots.incl(fn.name)
      pending.add(fn.name)
  if pending.len == 0:
    return

  var definitions, imports, accessed, used = initHashSet[string]()
  proc use(value: Value)
  proc use(value: Value) =
    if value.kind != Flavor.Global: return
    if functions.hasKey(value.name) and value.name notin definitions:
      pending.add(value.name)
    elif value.name in externs:
      imports.incl(value.name)
    elif value.name in storage and value.name notin accessed:
      accessed.incl(value.name)
      use(stores[value.name].value)

  proc inspect(instruction: Instruction)
  proc inspect(body: Block) =
    if body == nil: return
    for instruction in body.instrs: inspect(instruction)
    inspect(body.term)
  proc inspect(instruction: Instruction) =
    if instruction == nil: return
    if instruction.kind in {Opcode.Call, Opcode.Thread} and
        instruction.func.len > 0:
      if functions.hasKey(instruction.func) and instruction.func notin definitions:
        pending.add(instruction.func)
      elif instruction.func in externs:
        imports.incl(instruction.func)
    if instruction.kind == Opcode.Native and instruction.symbol.len > 0:
      used.incl(instruction.symbol)
    for value in [instruction.target, instruction.ptr, instruction.val,
        instruction.val2, instruction.callee, instruction.cond,
        instruction.value, instruction.expr]:
      use(value)
    for value in instruction.args: use(value)
    for value in instruction.positive: use(value)
    for value in instruction.negative: use(value)
    for edge in instruction.blocks: use(edge.value)
    inspect(instruction.fallback)
    for section in instruction.fallbackBlocks: inspect(section)

  if library:
    for item in result.storage:
      if item.public and item.name notin accessed:
        accessed.incl(item.name)
        use(item.value)

  var position = 0
  while position < pending.len:
    let name = pending[position]
    inc position
    if name in definitions or not functions.hasKey(name): continue
    definitions.incl(name)
    for body in functions[name].blocks: inspect(body)

  var routines: seq[node.Function]
  for fn in result.funcs:
    if fn.name in definitions: routines.add(fn)
  result.funcs = routines

  var externals: seq[Extern]
  for declaration in result.externs:
    if declaration.name in imports: externals.add(declaration)
  result.externs = externals

  var retained: seq[Storage]
  for item in result.storage:
    if (item.public and library) or item.name in accessed:
      retained.add(item)
  result.storage = retained

  var kept: seq[Contract]
  for contract in result.native:
    if contract.id in used: kept.add(contract)
  result.native = kept

  var survivors: seq[Trace]
  for trace in result.traces:
    if trace.function in definitions: survivors.add(trace)
  result.traces = survivors
