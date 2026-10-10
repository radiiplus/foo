import std/[sequtils, sets, tables]
import ../ir/[kind, node]
import ./arch
import ./engine as selection

type
  Operand = object
    valid: bool
    indexed: bool
    value: Value

  Pattern = object
    counter: Value
    bound: Value
    start: Value
    first: Operand
    second: Operand
    post: Operand
    output: Value
    width: int
    operation: int
    follow: int
    postLeft: bool
    ending: string

proc register(value, expected: Value): bool =
  value.kind == ValueKind.Reg and expected.kind == ValueKind.Reg and
    value.name == expected.name

proc load(instruction: Instruction; pointer: Value): bool =
  instruction.kind == InstrKind.Load and instruction.ptr.register(pointer)

proc scalar(value: `Type`; width: int): bool =
  value != nil and value.kind == TypeKind.Float and value.width == width and
    not value.volatile

proc slice(value: Value; width: int): bool =
  value.`type` != nil and value.`type`.kind == TypeKind.Slice and
    not value.`type`.volatile and value.`type`.elem.scalar(width)

proc opcode(kind: InstrKind): int =
  case kind
  of InstrKind.Add: 0
  of InstrKind.Sub: 1
  of InstrKind.Mul: 2
  of InstrKind.Div: 3
  else: 4

proc operand(value: Value; width: int; reads: Table[string, Value];
    parameters: HashSet[string]; used: var HashSet[string]): Operand =
  if value.kind == ValueKind.Reg and reads.hasKey(value.name):
    let source = reads[value.name]
    if source.slice(width):
      used.incl(value.name)
      return Operand(valid: true, indexed: true, value: source)
  if value.`type`.scalar(width) and (value.kind == ValueKind.Const or
      (value.kind == ValueKind.Reg and value.name in parameters)):
    return Operand(valid: true, value: value)

proc zero(width: int): Value =
  Value(kind: ValueKind.Const, name: "0.0",
    `type`: `Type`(kind: TypeKind.Float, width: width))

proc numeric(value: Operand; width: int): Value =
  if value.valid and not value.indexed: value.value else: zero(width)

proc incoming(function: Function; label: string): int =
  for basicBlock in function.blocks:
    if basicBlock.term == nil: continue
    if basicBlock.term.kind == InstrKind.Jump and basicBlock.term.label == label:
      inc result
    elif basicBlock.term.kind == InstrKind.Cjump:
      if basicBlock.term.trueLabel == label: inc result
      if basicBlock.term.falseLabel == label: inc result

# Match only loops whose indexed reads and write have no intervening effects.
proc match(function: Function; entry: Block;
    blocks: Table[string, Block]): Pattern =
  if entry.term == nil or entry.term.kind != InstrKind.Jump or
      entry.instrs.len < 2 or not blocks.hasKey(entry.term.label): return
  let head = blocks[entry.term.label]
  if head.instrs.len != 2 or head.term == nil or
      head.term.kind != InstrKind.Cjump or
      head.instrs[0].kind != InstrKind.Load or
      head.instrs[1].kind != InstrKind.Compare or
      head.instrs[1].op != "is less than" or
      not head.instrs[1].val.register(head.instrs[0].dest) or
      not head.term.cond.register(head.instrs[1].dest) or
      head.instrs[1].val2.`type` == nil or
      head.instrs[1].val2.`type`.kind != TypeKind.Uint or
      head.instrs[1].val2.`type`.width != 64 or
      not blocks.hasKey(head.term.trueLabel) or
      not blocks.hasKey(head.term.falseLabel) or
      function.incoming(head.label) != 2 or
      function.incoming(head.term.trueLabel) != 1 or
      function.incoming(head.term.falseLabel) != 1: return
  let counter = head.instrs[0].ptr
  if counter.`type` == nil or counter.`type`.kind != TypeKind.Ptr or
      counter.`type`.elem == nil or
      counter.`type`.elem.kind != TypeKind.Uint or
      counter.`type`.elem.width != 64: return
  var start: Value
  var initialized = false
  var parameters = initHashSet[string]()
  for parameter in function.params: parameters.incl(parameter.name)
  for position in 0 ..< (entry.instrs.len - 1):
    let allocation = entry.instrs[position]
    let initial = entry.instrs[position + 1]
    if allocation.kind == InstrKind.Alloc and allocation.op == "slot" and
        allocation.dest.register(counter) and
        initial.kind == InstrKind.Store and
        initial.ptr.register(counter) and
        (initial.val.kind == ValueKind.Const or
          (initial.val.kind == ValueKind.Reg and
            initial.val.name in parameters)) and
        initial.val.`type` != nil and
        initial.val.`type`.kind == TypeKind.Uint and
        initial.val.`type`.width == 64:
      start = initial.val
      initialized = true
  if not initialized: return
  let body = blocks[head.term.trueLabel]
  let ending = blocks[head.term.falseLabel]
  if body.instrs.len < 6 or body.term == nil or
      body.term.kind != InstrKind.Jump or body.term.label != head.label or
      ending.params.anyIt(it.`type` == nil or it.`type`.kind != TypeKind.Memory):
    return
  let steps = body.instrs
  let store = steps[^4]
  let advance = steps[^2]
  if not steps[0].load(counter) or
      steps[1].kind != InstrKind.Index or steps[1].op != "address" or
      not steps[1].val2.register(steps[0].dest) or
      store.kind != InstrKind.Store or
      not store.ptr.register(steps[1].dest) or
      not steps[^3].load(counter) or
      advance.kind != InstrKind.Add or
      not advance.val.register(steps[^3].dest) or
      advance.val2.kind != ValueKind.Const or advance.val2.name != "1" or
      steps[^1].kind != InstrKind.Store or
      not steps[^1].ptr.register(counter) or
      not steps[^1].val.register(advance.dest): return
  let width = if steps[1].val.`type` != nil and
      steps[1].val.`type`.elem != nil:
      steps[1].val.`type`.elem.width else: 0
  if width notin [32, 64] or not steps[1].val.slice(width): return
  var reads = initTable[string, Value]()
  var arithmetic: seq[Instruction]
  var position = 2
  let stop = steps.len - 4
  while position < stop:
    let instruction = steps[position]
    if instruction.load(counter) and position + 1 < stop:
      let indexed = steps[position + 1]
      if indexed.kind != InstrKind.Index or indexed.op == "address" or
          not indexed.val2.register(instruction.dest) or
          not indexed.val.slice(width) or
          indexed.dest.kind != ValueKind.Reg or
          reads.hasKey(indexed.dest.name): return
      reads[indexed.dest.name] = indexed.val
      position += 2
    elif instruction.kind in {InstrKind.Add, InstrKind.Sub,
        InstrKind.Mul, InstrKind.Div} and
        instruction.dest.`type`.scalar(width) and
        instruction.panic.len == 0:
      arithmetic.add(instruction)
      inc position
    else: return
  if reads.len > 2 or arithmetic.len > 2: return
  var used = initHashSet[string]()
  var first, second, post: Operand
  var operation = 4
  var follow = 4
  var postLeft = false
  if arithmetic.len == 0:
    first = operand(store.val, width, reads, parameters, used)
    second = Operand(valid: true, value: zero(width))
  else:
    let current = arithmetic[0]
    first = operand(current.val, width, reads, parameters, used)
    second = operand(current.val2, width, reads, parameters, used)
    operation = opcode(current.kind)
    if arithmetic.len == 1:
      if not store.val.register(current.dest): return
    else:
      let next = arithmetic[1]
      if not store.val.register(next.dest): return
      if next.val.register(current.dest):
        post = operand(next.val2, width, reads, parameters, used)
      elif next.val2.register(current.dest):
        post = operand(next.val, width, reads, parameters, used)
        postLeft = true
      else: return
      if not post.valid or post.indexed: return
      follow = opcode(next.kind)
  if not first.valid or not second.valid or used.len != reads.len: return
  result = Pattern(counter: counter, bound: head.instrs[1].val2,
    start: start, first: first, second: second, post: post,
    output: steps[1].val, width: width, operation: operation,
    follow: follow, postLeft: postLeft, ending: ending.label)

proc apply*(module: Module; backend, target, cpu, mode: string): int =
  let architecture = arch.architecture(target)
  let profile = arch.profile(target, cpu)
  let context = selection.Context(backend: backend, target: target,
    cpu: profile.cpu, mode: mode)
  let decision = selection.choose("vectorize", "ordered decimal lanes", context, [
    selection.candidate("scalar", "@foo", "ordered decimal lanes",
      "the original checked loop preserves every input and failure", 0,
      fallback = true),
    selection.candidate("simd", "@runtime", "ordered decimal lanes",
      "runtime guards permit independent decimal lanes", 20,
      compatible = architecture in ["x86_64", "aarch64"],
      backends = @["c", "zig"], modes = @["release"])
  ])
  if decision.implementation != "simd": return
  var names = initHashSet[string]()
  for function in module.funcs: names.incl(function.name)
  for external in module.externs: names.incl(external.name)
  var declarations = initTable[int, string]()
  var serial = 0
  for function in module.funcs:
    var blocks = initTable[string, Block]()
    for basicBlock in function.blocks: blocks[basicBlock.label] = basicBlock
    for entry in function.blocks:
      let pattern = function.match(entry, blocks)
      if pattern.width == 0: continue
      var external = declarations.getOrDefault(pattern.width)
      if external.len == 0:
        external = "vector" & $pattern.width
        while external in names:
          inc serial
          external = "vector" & $pattern.width & $serial
        names.incl(external)
        declarations[pattern.width] = external
        let number = `Type`(kind: TypeKind.Uint, width: 64)
        let decimal = `Type`(kind: TypeKind.Float, width: pattern.width)
        module.externs.add(Extern(name: external, symbol: "vectorize",
          abi: "runtime.cpu", ret: `Type`(kind: TypeKind.Bool),
          params: @[pattern.output.`type`, pattern.output.`type`,
            pattern.output.`type`, number, number, number, number, number,
            decimal, decimal, number, decimal, pattern.counter.`type`]))
      let number = `Type`(kind: TypeKind.Uint, width: 64)
      let flags = (if pattern.first.indexed: 0 else: 1) +
        (if pattern.second.indexed: 0 else: 2) +
        (if pattern.postLeft: 4 else: 0)
      let selected = Value(kind: ValueKind.Reg,
        name: "vector" & $pattern.width & $serial & $result,
        `type`: `Type`(kind: TypeKind.Bool))
      entry.instrs.add(Instruction(kind: InstrKind.Call, dest: selected,
        `func`: external, symbol: "vectorize", abi: "runtime.cpu",
        args: @[(if pattern.first.indexed: pattern.first.value else: pattern.output),
          (if pattern.second.indexed: pattern.second.value else: pattern.output),
          pattern.output,
          pattern.bound, Value(kind: ValueKind.Const, name: $pattern.width,
            `type`: number), Value(kind: ValueKind.Const,
            name: $pattern.operation, `type`: number), pattern.start,
          Value(kind: ValueKind.Const, name: $flags, `type`: number),
          numeric(pattern.first, pattern.width),
          numeric(pattern.second, pattern.width),
          Value(kind: ValueKind.Const, name: $pattern.follow, `type`: number),
          numeric(pattern.post, pattern.width), pattern.counter],
        effects: @["read", "write"]))
      entry.term = Instruction(kind: InstrKind.Cjump, cond: selected,
        trueLabel: pattern.ending, falseLabel: entry.term.label)
      inc result
