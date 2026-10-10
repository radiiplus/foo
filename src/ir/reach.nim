import std/[sets, tables]
import ./[kind, monomorph, node]

proc reach*(input: Module; library = false): Module =
  result = cloneModule(input)
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
        "interrupt" in fn.attributes or (fn.abi.len > 0 and fn.abi != "gpu") or
        (library and fn.public):
      roots.incl(fn.name)
      pending.add(fn.name)
  if pending.len == 0:
    return

  var usedFunctions, usedExterns, usedStorage, usedNative = initHashSet[string]()
  proc use(value: Value)
  proc use(value: Value) =
    if value.kind != ValueKind.Global: return
    if functions.hasKey(value.name) and value.name notin usedFunctions:
      pending.add(value.name)
    elif value.name in externs:
      usedExterns.incl(value.name)
    elif value.name in storage and value.name notin usedStorage:
      usedStorage.incl(value.name)
      use(stores[value.name].value)

  proc inspect(instruction: Instruction)
  proc inspect(body: Block) =
    if body == nil: return
    for instruction in body.instrs: inspect(instruction)
    inspect(body.term)
  proc inspect(instruction: Instruction) =
    if instruction == nil: return
    if instruction.kind in {InstrKind.Call, InstrKind.Thread} and
        instruction.func.len > 0:
      if functions.hasKey(instruction.func) and instruction.func notin usedFunctions:
        pending.add(instruction.func)
      elif instruction.func in externs:
        usedExterns.incl(instruction.func)
    if instruction.kind == InstrKind.Native and instruction.symbol.len > 0:
      usedNative.incl(instruction.symbol)
    for value in [instruction.target, instruction.ptr, instruction.val,
        instruction.val2, instruction.callee, instruction.cond,
        instruction.value, instruction.expr]:
      use(value)
    for value in instruction.args: use(value)
    for value in instruction.trueArgs: use(value)
    for value in instruction.falseArgs: use(value)
    for edge in instruction.blocks: use(edge.value)
    inspect(instruction.fallback)

  if library:
    for item in result.storage:
      if item.public and item.name notin usedStorage:
        usedStorage.incl(item.name)
        use(item.value)

  var position = 0
  while position < pending.len:
    let name = pending[position]
    inc position
    if name in usedFunctions or not functions.hasKey(name): continue
    usedFunctions.incl(name)
    for body in functions[name].blocks: inspect(body)

  var keptFunctions: seq[node.Function]
  for fn in result.funcs:
    if fn.name in usedFunctions: keptFunctions.add(fn)
  result.funcs = keptFunctions

  var keptExterns: seq[Extern]
  for declaration in result.externs:
    if declaration.name in usedExterns: keptExterns.add(declaration)
  result.externs = keptExterns

  var keptStorage: seq[Storage]
  for item in result.storage:
    if (item.public and library) or item.name in usedStorage:
      keptStorage.add(item)
  result.storage = keptStorage

  var keptNative: seq[NativeContract]
  for contract in result.native:
    if contract.id in usedNative: keptNative.add(contract)
  result.native = keptNative

  var keptTraces: seq[Trace]
  for trace in result.traces:
    if trace.function in usedFunctions: keptTraces.add(trace)
  result.traces = keptTraces
