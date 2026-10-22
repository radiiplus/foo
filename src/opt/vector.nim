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
    following: bool
    ending: string

proc register(value, expected: Value): bool =
  value.kind == Flavor.Reg and expected.kind == Flavor.Reg and
    value.name == expected.name

proc load(instruction: Instruction; pointer: Value): bool =
  instruction.kind == Opcode.Load and instruction.ptr.register(pointer)

proc scalar(value: `Type`; width: int): bool =
  value != nil and value.kind == Shape.Float and value.width == width and
    not value.volatile

proc slice(value: Value; width: int): bool =
  value.`type` != nil and value.`type`.kind == Shape.Slice and
    not value.`type`.volatile and value.`type`.elem.scalar(width)

proc opcode(kind: Opcode): int =
  case kind
  of Opcode.Add: 0
  of Opcode.Sub: 1
  of Opcode.Mul: 2
  of Opcode.Div: 3
  else: 4

proc operand(value: Value; width: int; reads: Table[string, Value];
    parameters: HashSet[string]; used: var HashSet[string]): Operand =
  if value.kind == Flavor.Reg and reads.hasKey(value.name):
    let source = reads[value.name]
    if source.slice(width):
      used.incl(value.name)
      return Operand(valid: true, indexed: true, value: source)
  if value.`type`.scalar(width) and (value.kind == Flavor.Const or
      (value.kind == Flavor.Reg and value.name in parameters)):
    return Operand(valid: true, value: value)

proc zero(width: int): Value =
  Value(kind: Flavor.Const, name: "0.0",
    `type`: `Type`(kind: Shape.Float, width: width))

proc numeric(value: Operand; width: int): Value =
  if value.valid and not value.indexed: value.value else: zero(width)

proc incoming(function: Function; label: string): int =
  for section in function.blocks:
    if section.term == nil: continue
    if section.term.kind == Opcode.Jump and section.term.label == label:
      inc result
    elif section.term.kind == Opcode.Cjump:
      if section.term.yes == label: inc result
      if section.term.no == label: inc result

# Match only loops whose indexed reads and write have no intervening effects.
proc match(function: Function; entry: Block;
    blocks: Table[string, Block]): Pattern =
  if entry.term == nil or entry.term.kind != Opcode.Jump or
      entry.instrs.len < 2 or not blocks.hasKey(entry.term.label): return
  let head = blocks[entry.term.label]
  if head.instrs.len != 2 or head.term == nil or
      head.term.kind != Opcode.Cjump or
      head.instrs[0].kind != Opcode.Load or
      head.instrs[1].kind != Opcode.Compare or
      head.instrs[1].op != "is less than" or
      not head.instrs[1].val.register(head.instrs[0].dest) or
      not head.term.cond.register(head.instrs[1].dest) or
      head.instrs[1].val2.`type` == nil or
      head.instrs[1].val2.`type`.kind != Shape.Uint or
      head.instrs[1].val2.`type`.width != 64 or
      not blocks.hasKey(head.term.yes) or
      not blocks.hasKey(head.term.no) or
      function.incoming(head.label) != 2 or
      function.incoming(head.term.yes) != 1 or
      function.incoming(head.term.no) != 1: return
  let counter = head.instrs[0].ptr
  if counter.`type` == nil or counter.`type`.kind != Shape.Ptr or
      counter.`type`.elem == nil or
      counter.`type`.elem.kind != Shape.Uint or
      counter.`type`.elem.width != 64: return
  var start: Value
  var initialized = false
  var parameters = initHashSet[string]()
  for parameter in function.params: parameters.incl(parameter.name)
  for position in 0 ..< (entry.instrs.len - 1):
    let allocation = entry.instrs[position]
    let initial = entry.instrs[position + 1]
    if allocation.kind == Opcode.Alloc and allocation.op == "slot" and
        allocation.dest.register(counter) and
        initial.kind == Opcode.Store and
        initial.ptr.register(counter) and
        (initial.val.kind == Flavor.Const or
          (initial.val.kind == Flavor.Reg and
            initial.val.name in parameters)) and
        initial.val.`type` != nil and
        initial.val.`type`.kind == Shape.Uint and
        initial.val.`type`.width == 64:
      start = initial.val
      initialized = true
  if not initialized: return
  let body = blocks[head.term.yes]
  let ending = blocks[head.term.no]
  if body.instrs.len < 6 or body.term == nil or
      body.term.kind != Opcode.Jump or body.term.label != head.label or
      ending.params.anyIt(it.`type` == nil or it.`type`.kind != Shape.Memory):
    return
  let steps = body.instrs
  let store = steps[^4]
  let advance = steps[^2]
  if not steps[0].load(counter) or
      steps[1].kind != Opcode.Index or steps[1].op != "address" or
      not steps[1].val2.register(steps[0].dest) or
      store.kind != Opcode.Store or
      not store.ptr.register(steps[1].dest) or
      not steps[^3].load(counter) or
      advance.kind != Opcode.Add or
      not advance.val.register(steps[^3].dest) or
      advance.val2.kind != Flavor.Const or advance.val2.name != "1" or
      steps[^1].kind != Opcode.Store or
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
      if indexed.kind != Opcode.Index or indexed.op == "address" or
          not indexed.val2.register(instruction.dest) or
          not indexed.val.slice(width) or
          indexed.dest.kind != Flavor.Reg or
          reads.hasKey(indexed.dest.name): return
      reads[indexed.dest.name] = indexed.val
      position += 2
    elif instruction.kind in {Opcode.Add, Opcode.Sub,
        Opcode.Mul, Opcode.Div} and
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
  var following = false
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
        following = true
      else: return
      if not post.valid or post.indexed: return
      follow = opcode(next.kind)
  if not first.valid or not second.valid or used.len != reads.len: return
  result = Pattern(counter: counter, bound: head.instrs[1].val2,
    start: start, first: first, second: second, post: post,
    output: steps[1].val, width: width, operation: operation,
    follow: follow, following: following, ending: ending.label)

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
      compatible = architecture == "x86_64", targets = @["windows"],
      backends = @["qbe"], modes = @["release"], evidenced = false)
  ])
  if decision.implementation != "simd": return
  var names = initHashSet[string]()
  for function in module.funcs: names.incl(function.name)
  for external in module.externs: names.incl(external.name)
  var declarations = initTable[int, string]()
  var serial = 0
  for function in module.funcs:
    var blocks = initTable[string, Block]()
    for section in function.blocks: blocks[section.label] = section
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
        let number = `Type`(kind: Shape.Uint, width: 64)
        let decimal = `Type`(kind: Shape.Float, width: pattern.width)
        module.externs.add(Extern(name: external, symbol: "vectorize",
          abi: "runtime.cpu", ret: `Type`(kind: Shape.Bool),
          params: @[pattern.output.`type`, pattern.output.`type`,
            pattern.output.`type`, number, number, number, number, number,
            decimal, decimal, number, decimal, pattern.counter.`type`]))
      let number = `Type`(kind: Shape.Uint, width: 64)
      let flags = (if pattern.first.indexed: 0 else: 1) +
        (if pattern.second.indexed: 0 else: 2) +
        (if pattern.following: 4 else: 0)
      let selected = Value(kind: Flavor.Reg,
        name: "vector" & $pattern.width & $serial & $result,
        `type`: `Type`(kind: Shape.Bool))
      entry.instrs.add(Instruction(kind: Opcode.Call, dest: selected,
        `func`: external, symbol: "vectorize", abi: "runtime.cpu",
        args: @[(if pattern.first.indexed: pattern.first.value else: pattern.output),
          (if pattern.second.indexed: pattern.second.value else: pattern.output),
          pattern.output,
          pattern.bound, Value(kind: Flavor.Const, name: $pattern.width,
            `type`: number), Value(kind: Flavor.Const,
            name: $pattern.operation, `type`: number), pattern.start,
          Value(kind: Flavor.Const, name: $flags, `type`: number),
          numeric(pattern.first, pattern.width),
          numeric(pattern.second, pattern.width),
          Value(kind: Flavor.Const, name: $pattern.follow, `type`: number),
          numeric(pattern.post, pattern.width), pattern.counter],
        effects: @["read", "write"]))
      entry.term = Instruction(kind: Opcode.Cjump, cond: selected,
        yes: pattern.ending, no: entry.term.label)
      inc result
