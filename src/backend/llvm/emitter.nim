## Typed IR lowering; typing, specialization and ownership stay in the frontend.
import std/[algorithm, json, os, sequtils, strutils, tables, sets]
import ../../ir/[node, kind, monomorph]
import ./layout
import ./runtime
import ./abi
import ../../opt/arch as targetArch

type
  State = ref object
    globals, declarations, functions: seq[string]
    externs: Table[string, Extern]
    intrinsics: HashSet[string]
    source: string
    hosted: bool
    contracts: Table[string, NativeContract]
    machineFunctions: HashSet[string]
  Context = ref object
    state: State
    fn: Function
    lines, prologue: seq[string]
    registers, cells, regions: Table[string, string]
    cleanups: seq[tuple[body: Block, flag: string, onError: bool]]
    allocations: seq[string]
    blocks: Table[string, Block]
    serial: int
    current: string
    location: SourceSpan

proc llvmString(value: string): string =
  result = "\""
  for character in value:
    if character < ' ' or character > '~' or character in {'\"', '\\'}:
      result.add("\\" & toHex(ord(character), 2))
    else: result.add(character)
  result.add('"')
proc symbol(name: string): string = "@" & llvmString("foo." & name)
proc label(name: string): string = "b" & name.toHex()
proc fresh(ctx: Context): string =
  inc ctx.serial
  "%v" & $ctx.serial
proc add(ctx: Context; line: string) = ctx.lines.add("  " & line)
proc mark(ctx: Context; name: string) = ctx.lines.add(name & ":")
proc slot(ctx: Context; size, alignment: int): string =
  result = ctx.fresh()
  # Alignment is proved for our own allocations, never assumed for callers.
  ctx.prologue.add("  " & result & " = alloca [" & $size & " x i8], align " & $alignment)
proc temporary(ctx: Context; t: node.Type): string = ctx.slot(max(1, measure(t).size), measure(t).alignment)
proc literal(state: State; data: openArray[byte]): string =
  result = "@str" & $state.globals.len
  var text: string
  for b in data: text.add("\\" & toHex(b, 2))
  state.globals.add(result & " = private constant [" & $(data.len + 1) & " x i8] c\"" & text & "\\00\"")
proc literal(state: State; text: string): string = state.literal(text.toOpenArrayByte(0, text.high))
proc gep(ctx: Context; pointer: string; offset: int): string =
  if offset == 0: return pointer
  result = ctx.fresh(); ctx.add(result & " = getelementptr i8, ptr " & pointer & ", i64 " & $offset)
proc load(ctx: Context; t: node.Type; pointer: string; volatileAccess = false): string =
  if llvmType(t) == "void": return "zeroinitializer"
  let qualifier = if volatileAccess: "volatile " else: ""
  result = ctx.fresh(); ctx.add(result & " = load " & qualifier & llvmType(t) & ", ptr " & pointer & ", align 1")
proc store(ctx: Context; t: node.Type; text, pointer: string; volatileAccess = false) =
  let qualifier = if volatileAccess: "volatile " else: ""
  if llvmType(t) != "void": ctx.add("store " & qualifier & llvmType(t) & " " & text & ", ptr " & pointer & ", align 1")
proc boxed(ctx: Context; t: node.Type; text: string): string =
  result = ctx.temporary(t); ctx.store(t, text, result)
proc value(ctx: Context; v: Value): string
proc converted(ctx: Context; text: string; source, target: node.Type): string
proc instruction(ctx: Context; i: Instruction)

proc value(ctx: Context; v: Value): string =
  let t = v.type
  if t == nil or t.kind == TypeKind.Void: return "zeroinitializer"
  case v.kind
  of ValueKind.Reg:
    if not ctx.registers.hasKey(v.name): raise newException(ValueError, "undefined IR register " & v.name)
    return ctx.load(t, ctx.registers[v.name])
  of ValueKind.Global:
    if v.name in ctx.state.machineFunctions: return symbol(v.name)
    if t.kind == TypeKind.Function: return "@" & callbackName(v.name)
    if t.kind == TypeKind.Ptr: return symbol(v.name)
    return ctx.load(t, symbol(v.name))
  of ValueKind.Const:
    let text = if v.name.len > 0: v.name else: v.bits
    if text in ["null", "{}", "void", "undefined"]: return "zeroinitializer"
    if t.kind in {TypeKind.Int, TypeKind.Uint}: return if v.bits.len > 0: v.bits else: text
    if t.kind == TypeKind.Bool: return if text == "true": "1" else: "0"
    if t.kind == TypeKind.Float:
      let number = parseFloat(text)
      let bits = if t.width == 32: cast[uint64](float64(float32(number))) else: cast[uint64](number)
      return "0x" & toHex(bits, 16)
    if t.kind == TypeKind.Error: return ctx.state.literal(text)
    if t.kind == TypeKind.Ptr: return "null"
    if t.kind == TypeKind.Slice:
      let data = node.bytes(text); let pointer = ctx.state.literal(data)
      let memory = ctx.temporary(t); ctx.store(t, "zeroinitializer", memory)
      ctx.add("store ptr " & pointer & ", ptr " & memory & ", align 1")
      ctx.add("store i64 " & $data.len & ", ptr " & ctx.gep(memory, 8) & ", align 1")
      return ctx.load(t, memory)
    raise newException(ValueError, "unsupported constant " & t.label)
proc put(ctx: Context; v: Value; text: string) =
  if v.type != nil and v.type.kind != TypeKind.Void: ctx.store(v.type, text, ctx.registers[v.name])
proc op(ctx: Context; opcode, ty, a, b: string): string =
  result = ctx.fresh(); ctx.add(result & " = " & opcode & " " & ty & " " & a & ", " & b)
proc byteBool(ctx: Context; text: string): string =
  result = ctx.fresh(); ctx.add(result & " = zext i1 " & text & " to i8")
proc guard(ctx: Context; failed, message: string) =
  let failure = "failure" & $ctx.serial; let success = "continue" & $ctx.serial
  ctx.add("br i1 " & failed & ", label %" & failure & ", label %" & success); ctx.mark(failure)
  if ctx.state.hosted:
    ctx.add("call void @foo_llvm_trace(ptr " & ctx.state.literal(ctx.fn.name) & ", ptr " & ctx.state.literal(ctx.location.file) & ", i64 " & $ctx.location.start & ")")
    ctx.add("call void @foo_llvm_panic(ptr " & ctx.state.literal(message) & ")")
  else: ctx.add("call void @llvm.trap()")
  ctx.add("unreachable"); ctx.mark(success)
proc converted(ctx: Context; text: string; source, target: node.Type): string =
  if target.kind in {TypeKind.Optional, TypeKind.Failable} and (source == nil or source.kind != target.kind):
    let memory = ctx.temporary(target); ctx.store(target, "zeroinitializer", memory)
    if target.kind == TypeKind.Optional: ctx.add("store i8 1, ptr " & memory & ", align 1")
    if source != nil and source.kind != TypeKind.Void: ctx.store(target.elem, ctx.converted(text, source, target.elem), ctx.gep(memory, measure(target).offsets[1]))
    return ctx.load(target, memory)
  if llvmType(source) == llvmType(target): return text
  let sourceInt = source.kind in {TypeKind.Int, TypeKind.Uint, TypeKind.Bool}
  let targetInt = target.kind in {TypeKind.Int, TypeKind.Uint, TypeKind.Bool}
  var opcode: string
  if sourceInt and targetInt:
    if measure(source).size > measure(target).size: raise newException(ValueError, "narrowing conversion lacks a checked frontend contract")
    opcode = if source.kind == TypeKind.Int: "sext" else: "zext"
  elif sourceInt and target.kind == TypeKind.Float: opcode = if source.kind == TypeKind.Int: "sitofp" else: "uitofp"
  elif source.kind == TypeKind.Float and target.kind == TypeKind.Float: opcode = if source.width < target.width: "fpext" else: "fptrunc"
  else: raise newException(ValueError, "unsupported conversion " & source.label & " to " & target.label)
  result = ctx.fresh(); ctx.add(result & " = " & opcode & " " & llvmType(source) & " " & text & " to " & llvmType(target))
proc assign(ctx: Context; expected: node.Type; v: Value): string = ctx.converted(ctx.value(v), v.type, expected)
proc numeric(ctx: Context; i: Instruction; a, b: string): string =
  let t = i.dest.type
  if t.kind == TypeKind.Float:
    let opcode = case i.kind
      of InstrKind.Add: "fadd"
      of InstrKind.Sub: "fsub"
      of InstrKind.Mul: "fmul"
      of InstrKind.Div: "fdiv"
      else: raise newException(ValueError, "decimal remainder is not in the language IR")
    return ctx.op(opcode, llvmType(t), a, b)
  if t.kind notin {TypeKind.Int, TypeKind.Uint}: raise newException(ValueError, "numeric type required")
  let n = width(t); let ty = "i" & $n
  var left = a; var right = b
  if n != storageWidth(t):
    left = ctx.fresh(); ctx.add(left & " = trunc " & llvmType(t) & " " & a & " to " & ty)
    right = ctx.fresh(); ctx.add(right & " = trunc " & llvmType(t) & " " & b & " to " & ty)
  var computed: string
  if i.kind in {InstrKind.Add, InstrKind.Sub, InstrKind.Mul}:
    let intrinsic = "llvm." & (if t.kind == TypeKind.Int: "s" else: "u") & ($i.kind).toLowerAscii & ".with.overflow." & ty
    ctx.state.intrinsics.incl(intrinsic)
    let pair = ctx.fresh(); computed = ctx.fresh(); let failed = ctx.fresh()
    ctx.add(pair & " = call { " & ty & ", i1 } @" & intrinsic & "(" & ty & " " & left & ", " & ty & " " & right & ")")
    ctx.add(computed & " = extractvalue { " & ty & ", i1 } " & pair & ", 0")
    ctx.add(failed & " = extractvalue { " & ty & ", i1 } " & pair & ", 1")
    ctx.guard(failed, "IntegerOverflow")
  else:
    ctx.guard(ctx.op("icmp eq", ty, right, "0"), "DivisionByZero")
    if t.kind == TypeKind.Int:
      let minimum = ctx.op("shl", ty, "1", $(n - 1))
      let overflow = ctx.op("and", "i1", ctx.op("icmp eq", ty, left, minimum), ctx.op("icmp eq", ty, right, "-1"))
      if i.kind == InstrKind.Div: ctx.guard(overflow, "IntegerOverflow")
      else:
        let safe = ctx.fresh(); ctx.add(safe & " = select i1 " & overflow & ", " & ty & " 1, " & ty & " " & right)
        right = safe # srem minimum/-1 is poison; safe divisor 1 gives exact zero
    computed = ctx.op((if t.kind == TypeKind.Int: "s" else: "u") & (if i.kind == InstrKind.Div: "div" else: "rem"), ty, left, right)
  if n == storageWidth(t): return computed
  result = ctx.fresh(); ctx.add(result & " = " & (if t.kind == TypeKind.Int: "sext" else: "zext") & " " & ty & " " & computed & " to " & llvmType(t))
proc compare(ctx: Context; t: node.Type; a, b, relation: string): string =
  let relations = {"equals": "eq", "does not equal": "ne", "is less than": "lt", "is greater than": "gt", "is at most": "le", "is at least": "ge"}.toTable
  if not relations.hasKey(relation): raise newException(ValueError, "unknown comparison " & relation)
  let rel = relations[relation]
  if not aggregate(t):
    if t.kind == TypeKind.Float: return ctx.op("fcmp " & (if rel == "ne": "une" else: "o" & rel), llvmType(t), a, b)
    return ctx.op("icmp " & (if rel in ["eq", "ne"]: rel else: (if t.kind == TypeKind.Int: "s" else: "u") & rel), llvmType(t), a, b)
  let left = ctx.boxed(t, a); let right = ctx.boxed(t, b); let order = ctx.fresh()
  let comparator = comparisonName(t, relation); ctx.state.intrinsics.incl("compare:" & comparator)
  ctx.add(order & " = call i8 @" & comparator & "(ptr " & left & ", ptr " & right & ")")
  ctx.op("icmp ne", "i8", order, "0")

proc cleanup(ctx: Context; failed: string) =
  for index in countdown(ctx.cleanups.high, 0):
    let item = ctx.cleanups[index]; let enabled = ctx.fresh()
    ctx.add(enabled & " = load i1, ptr " & item.flag & ", align 1")
    let active = if item.onError: ctx.op("and", "i1", enabled, failed) else: enabled
    let body = "cleanup" & $ctx.serial; let done = "cleaned" & $ctx.serial
    ctx.add("br i1 " & active & ", label %" & body & ", label %" & done); ctx.mark(body)
    ctx.add("store i1 false, ptr " & item.flag & ", align 1")
    for child in item.body.instrs: ctx.instruction(child)
    ctx.add("br label %" & done); ctx.mark(done)
  for pointer in ctx.allocations: ctx.add("call void @free(ptr " & ctx.load(node.Type(kind: TypeKind.Ptr), pointer) & ")")
  for region in ctx.regions.values: ctx.add("call void @foo_llvm_close(ptr " & region & ")")
proc returned(ctx: Context; v: Value) =
  let t = ctx.fn.ret
  if t == nil or t.kind == TypeKind.Void:
    ctx.cleanup("false"); ctx.add("ret void"); return
  var text: string
  if v.type == nil or v.type.kind == TypeKind.Void:
    if t.kind == TypeKind.Failable and t.elem.kind == TypeKind.Void: text = "zeroinitializer"
    else: raise newException(ValueError, "missing return value in " & ctx.fn.name)
  else: text = ctx.assign(t, v)
  var failed = "false"
  if t.kind == TypeKind.Failable: failed = ctx.op("icmp ne", "ptr", ctx.load(node.Type(kind: TypeKind.Error), ctx.boxed(t, text)), "null")
  ctx.cleanup(failed); ctx.add("ret " & llvmType(t) & " " & text)
proc transfer(ctx: Context; target: string; arguments: seq[Value] = @[]) =
  if not ctx.blocks.hasKey(target): raise newException(ValueError, "unknown IR block " & target)
  var assignments: seq[tuple[v: Value, text: string]]
  for i in ctx.blocks[target].instrs:
    if i.kind != InstrKind.Phi: continue
    var found = false
    for incoming in i.blocks:
      if incoming.label == ctx.current:
        assignments.add((i.dest, ctx.assign(i.dest.type, incoming.value))); found = true
    if not found: raise newException(ValueError, "phi has no incoming edge from " & ctx.current)
  var index = 0
  for parameter in ctx.blocks[target].params:
    if parameter.type.kind == TypeKind.Memory: continue
    if index >= arguments.len: raise newException(ValueError, "block argument missing")
    assignments.add((parameter, ctx.assign(parameter.type, arguments[index]))); inc index
  for assignment in assignments: ctx.put(assignment.v, assignment.text)
  ctx.add("br label %" & label(target))

proc instruction(ctx: Context; i: Instruction) =
  if i == nil: return
  ctx.location = i.span
  ctx.lines.add("  ; " & $i.kind & " " & escape(i.span.file) & ":" & $i.span.start & ".." & $i.span.end)
  if not ctx.state.hosted and (i.kind in {InstrKind.Allocate, InstrKind.Region, InstrKind.Trace} or
      (i.kind == InstrKind.Alloc and i.op != "slot") or
      (i.kind == InstrKind.Add and i.dest.type.kind == TypeKind.Slice)):
    raise newException(ValueError, "runtime none cannot lower hosted allocation/text/issue-trail operation " & $i.kind)
  let t = i.dest.type
  case i.kind
  of InstrKind.Phi: discard
  of InstrKind.Alloc:
    if i.op == "slot":
      if not ctx.cells.hasKey(i.dest.name): ctx.cells[i.dest.name] = ctx.temporary(t.elem)
      ctx.put(i.dest, ctx.cells[i.dest.name])
    else:
      let pointer = ctx.fresh(); ctx.add(pointer & " = call ptr @foo_llvm_alloc(i64 " & $measure(t.elem).size & ")")
      ctx.put(i.dest, pointer)
      let owned = ctx.temporary(t)
      ctx.prologue.add("  store ptr null, ptr " & owned & ", align 1")
      ctx.store(t, pointer, owned); ctx.allocations.add(owned)
  of InstrKind.Load: ctx.put(i.dest, ctx.load(t, ctx.value(i.ptr), i.ptr.type.volatile or i.ptr.type.elem.volatile))
  of InstrKind.Store: ctx.store(i.ptr.type.elem, ctx.assign(i.ptr.type.elem, i.val), ctx.value(i.ptr), i.ptr.type.volatile or i.ptr.type.elem.volatile)
  of InstrKind.Add, InstrKind.Sub, InstrKind.Mul, InstrKind.Div, InstrKind.Remainder:
    if t.kind == TypeKind.Vector:
      let left = ctx.boxed(t, ctx.value(i.val)); let right = ctx.boxed(t, ctx.value(i.val2))
      let scalar = Instruction(kind: i.kind, dest: Value(type: t.elem))
      for lane in 0..<t.width:
        let offset = lane * measure(t.elem).size
        ctx.store(t.elem, ctx.numeric(scalar, ctx.load(t.elem, ctx.gep(left, offset)), ctx.load(t.elem, ctx.gep(right, offset))), ctx.gep(ctx.registers[i.dest.name], offset))
    elif t.kind == TypeKind.Slice and i.kind == InstrKind.Add:
      let a = ctx.boxed(t, ctx.value(i.val)); let b = ctx.boxed(t, ctx.value(i.val2))
      ctx.add("call void @foo_llvm_join(ptr " & ctx.registers[i.dest.name] & ", ptr " & a & ", ptr " & b & ")")
    else: ctx.put(i.dest, ctx.numeric(i, ctx.assign(t, i.val), ctx.assign(t, i.val2)))
  of InstrKind.Not: ctx.put(i.dest, ctx.byteBool(ctx.op("icmp eq", "i8", ctx.value(i.val), "0")))
  of InstrKind.Convert: ctx.put(i.dest, ctx.assign(t, i.val))
  of InstrKind.Compare:
    let typ = if i.val2.type.kind == TypeKind.Optional: i.val2.type else: i.val.type
    if typ.kind == TypeKind.Vector:
      let left = ctx.boxed(typ, ctx.value(i.val)); let right = ctx.boxed(typ, ctx.value(i.val2))
      for lane in 0..<typ.width:
        let offset = lane * measure(typ.elem).size
        ctx.store(t.elem, ctx.byteBool(ctx.compare(typ.elem, ctx.load(typ.elem, ctx.gep(left, offset)), ctx.load(typ.elem, ctx.gep(right, offset)), i.op)), ctx.gep(ctx.registers[i.dest.name], lane))
    else: ctx.put(i.dest, ctx.byteBool(ctx.compare(typ, ctx.assign(typ, i.val), ctx.assign(typ, i.val2), i.op)))
  of InstrKind.Splat:
    let value = ctx.assign(t.elem, i.val)
    for lane in 0..<t.width: ctx.store(t.elem, value, ctx.gep(ctx.registers[i.dest.name], lane * measure(t.elem).size))
  of InstrKind.Shuffle:
    let left = ctx.boxed(i.val.type, ctx.value(i.val)); let right = ctx.boxed(i.val2.type, ctx.value(i.val2))
    for index, lane in i.mask:
      if lane < 0 or lane >= i.val.type.width + i.val2.type.width: raise newException(ValueError, "shuffle lane out of bounds")
      let source = if lane < i.val.type.width: left else: right
      let position = if lane < i.val.type.width: lane else: lane - i.val.type.width
      ctx.store(t.elem, ctx.load(t.elem, ctx.gep(source, position * measure(t.elem).size)), ctx.gep(ctx.registers[i.dest.name], index * measure(t.elem).size))
  of InstrKind.Select:
    let mask = ctx.boxed(i.cond.type, ctx.value(i.cond))
    let left = ctx.boxed(t, ctx.value(i.val)); let right = ctx.boxed(t, ctx.value(i.val2))
    for lane in 0..<t.width:
      let offset = lane * measure(t.elem).size
      let condition = ctx.op("icmp ne", "i8", ctx.load(i.cond.type.elem, ctx.gep(mask, lane)), "0")
      let value = ctx.fresh()
      ctx.add(value & " = select i1 " & condition & ", " & llvmType(t.elem) & " " & ctx.load(t.elem, ctx.gep(left, offset)) & ", " & llvmType(t.elem) & " " & ctx.load(t.elem, ctx.gep(right, offset)))
      ctx.store(t.elem, value, ctx.gep(ctx.registers[i.dest.name], offset))
  of InstrKind.Gather, InstrKind.Scatter:
    let sourceType = i.val.type
    let source = ctx.boxed(sourceType, ctx.value(i.val))
    let indices = ctx.boxed(i.val2.type, ctx.value(i.val2))
    let output = ctx.registers[i.dest.name]
    if i.kind == InstrKind.Scatter: ctx.store(t, ctx.value(i.val), output)
    let values = if i.kind == InstrKind.Scatter: ctx.boxed(i.args[0].type, ctx.value(i.args[0])) else: ""
    for lane in 0..<i.val2.type.width:
      let indexType = i.val2.type.elem
      var index = ctx.load(indexType, ctx.gep(indices, lane * measure(indexType).size))
      index = ctx.converted(index, indexType, node.Type(kind: indexType.kind, width: 64))
      ctx.guard(ctx.op("icmp uge", "i64", index, $sourceType.width), "IndexOutOfBounds")
      let offset = ctx.op("mul", "i64", index, $measure(sourceType.elem).size)
      let pointer = ctx.fresh()
      ctx.add(pointer & " = getelementptr i8, ptr " & (if i.kind == InstrKind.Scatter: output else: source) & ", i64 " & offset)
      if i.kind == InstrKind.Gather: ctx.store(t.elem, ctx.load(t.elem, pointer), ctx.gep(output, lane * measure(t.elem).size))
      else: ctx.store(t.elem, ctx.load(t.elem, ctx.gep(values, lane * measure(t.elem).size)), pointer)
  of InstrKind.Reduce:
    let source = ctx.boxed(i.val.type, ctx.value(i.val))
    var value = ctx.load(t, source)
    let operation = if i.reduceOp.len == 0: "Add" else: i.reduceOp
    for lane in 1..<i.val.type.width:
      let next = ctx.load(t, ctx.gep(source, lane * measure(t).size))
      if operation in ["Add", "Mul"]:
        value = ctx.numeric(Instruction(kind: (if operation == "Add": InstrKind.Add else: InstrKind.Mul), dest: Value(type: t)), value, next)
      elif operation in ["Min", "Max"]:
        let chosen = ctx.compare(t, value, next, if operation == "Min": "is less than" else: "is greater than")
        let selected = ctx.fresh()
        ctx.add(selected & " = select i1 " & chosen & ", " & llvmType(t) & " " & value & ", " & llvmType(t) & " " & next)
        value = selected
      elif operation in ["And", "Or", "Xor"]: value = ctx.op(operation.toLowerAscii(), llvmType(t), value, next)
      else: raise newException(ValueError, "unknown vector reduction " & operation)
    ctx.put(i.dest, value)
  of InstrKind.Atomic:
    let order = case i.field
      of "relaxed": "monotonic"
      of "consume": "acquire"
      of "acquire", "release", "acq_rel", "seq_cst": i.field
      else: raise newException(ValueError, "unknown atomic ordering " & i.field)
    if i.op == "fence":
      if order != "monotonic": ctx.add("fence " & order)
    else:
      let element = i.ptr.type.elem
      if element.kind notin {TypeKind.Int, TypeKind.Uint, TypeKind.Bool, TypeKind.Ptr} or measure(element).size > 8:
        raise newException(ValueError, "atomic representation not qualified: " & element.label)
      let typ = llvmType(element)
      let alignment = $measure(element).alignment
      let pointer = ctx.value(i.ptr)
      if i.op == "store":
        ctx.add("store atomic " & typ & " " & ctx.assign(element, i.val) & ", ptr " & pointer & " " & order & ", align " & alignment)
      else:
        let value = ctx.fresh()
        if i.op == "load": ctx.add(value & " = load atomic " & typ & ", ptr " & pointer & " " & order & ", align " & alignment)
        elif i.op in ["add", "swap"]:
          ctx.add(value & " = atomicrmw " & (if i.op == "add": "add" else: "xchg") & " ptr " & pointer & ", " & typ & " " & ctx.assign(element, i.val) & " " & order & ", align " & alignment)
        else: raise newException(ValueError, "unsupported atomic operation " & i.op)
        if t != nil and t.kind != TypeKind.Void: ctx.put(i.dest, value)
  of InstrKind.Call, InstrKind.Thread:
    if ctx.state.externs.hasKey(i.func):
      let external = ctx.state.externs[i.func]
      var args = @["ptr " & (if t == nil or t.kind == TypeKind.Void: "null" else: ctx.registers[i.dest.name])]
      for index, arg in i.args: args.add("ptr " & ctx.boxed(external.params[index], ctx.assign(external.params[index], arg)))
      ctx.add("call void @" & bridgeName(external.name) & "(" & args.join(", ") & ")")
    elif i.callee.type != nil:
      let name = indirectName(i.callee.type)
      ctx.state.intrinsics.incl("indirect:" & name & ":" & $(i.args.len + 2))
      var args = @["ptr " & (if t == nil or t.kind == TypeKind.Void: "null" else: ctx.registers[i.dest.name]), "ptr " & ctx.value(i.callee)]
      for index, arg in i.args:
        let parameter = i.callee.type.params[index]
        args.add("ptr " & ctx.boxed(parameter, ctx.assign(parameter, arg)))
      ctx.add("call void @" & name & "(" & args.join(", ") & ")")
    else:
      let called = symbol(i.func)
      var args: seq[string]
      for arg in i.args: args.add(llvmType(arg.type) & " " & ctx.value(arg))
      let resultType = if t == nil: "void" else: llvmType(t)
      let returned = if resultType == "void": "" else: ctx.fresh()
      ctx.add((if returned.len > 0: returned & " = " else: "") & "call " & resultType & " " & called & "(" & args.join(", ") & ")")
      if returned.len > 0: ctx.put(i.dest, returned)
  of InstrKind.Construct:
    let memory = ctx.registers[i.dest.name]; ctx.store(t, "zeroinitializer", memory)
    if t.kind == TypeKind.Failable and i.op == "error": ctx.store(node.Type(kind: TypeKind.Error), ctx.value(i.args[0]), memory)
    elif t.kind == TypeKind.TaggedUnion:
      var index = 0; var found = false
      for name, typ in t.variants:
        if name == i.field:
          found = true; ctx.add("store i32 " & $index & ", ptr " & memory & ", align 1")
          if i.args.len > 0 and typ != nil and typ.kind != TypeKind.Void: ctx.store(typ, ctx.assign(typ, i.args[0]), ctx.gep(memory, measure(t).offsets[1]))
        inc index
      if not found: raise newException(ValueError, "unknown choice variant " & i.field)
    elif t.kind == TypeKind.Slice and i.op == "sequence":
      let backing = ctx.slot(max(1, measure(t.elem).size * i.args.len), measure(t.elem).alignment)
      for index, arg in i.args: ctx.store(t.elem, ctx.assign(t.elem, arg), ctx.gep(backing, index * measure(t.elem).size))
      ctx.add("store ptr " & backing & ", ptr " & memory & ", align 1")
      ctx.add("store i64 " & $i.args.len & ", ptr " & ctx.gep(memory, 8) & ", align 1")
    elif t.kind in {TypeKind.Struct, TypeKind.ExternStruct}:
      var index = 0
      for typ in t.fields.values:
        ctx.store(typ, ctx.assign(typ, i.args[index]), ctx.gep(memory, measure(t).offsets[index])); inc index
    elif t.kind in {TypeKind.Array, TypeKind.Vector}:
      for index, arg in i.args: ctx.store(t.elem, ctx.assign(t.elem, arg), ctx.gep(memory, index * measure(t.elem).size))
    else: raise newException(ValueError, "unsupported construction " & t.label)
  of InstrKind.Extract:
    let source = if i.ptr.type != nil: i.ptr else: i.val
    let typ = if source.type.kind == TypeKind.Ptr: source.type.elem else: source.type
    let memory = if source.type.kind == TypeKind.Ptr: ctx.value(source) else: ctx.boxed(typ, ctx.value(source))
    if typ.kind == TypeKind.Failable and i.field == "failed": ctx.put(i.dest, ctx.byteBool(ctx.op("icmp ne", "ptr", ctx.load(node.Type(kind: TypeKind.Error), memory), "null")))
    else:
      let offset = if typ.kind == TypeKind.Failable: measure(typ).offsets[1]
        elif typ.kind == TypeKind.Optional: (if i.field == "present": 0 else: measure(typ).offsets[1])
        elif typ.kind == TypeKind.TaggedUnion: (if i.field == "tag": 0 else: measure(typ).offsets[1])
        else: measure(typ).offsets[fieldIndex(typ, i.field)]
      let pointer = ctx.gep(memory, offset)
      ctx.put(i.dest, if i.op == "address": pointer else: ctx.load(t, pointer))
  of InstrKind.Length:
    let number = if i.val.type.kind == TypeKind.Slice:
        ctx.load(node.Type(kind: TypeKind.Uint, width: 64), ctx.gep(ctx.boxed(i.val.type, ctx.value(i.val)), 8)) else: $i.val.type.width
    ctx.put(i.dest, ctx.converted(number, node.Type(kind: TypeKind.Uint, width: 64), t))
  of InstrKind.Index:
    let typ = i.val.type; let memory = ctx.boxed(typ, ctx.value(i.val))
    let length = if typ.kind == TypeKind.Slice: ctx.load(node.Type(kind: TypeKind.Uint, width: 64), ctx.gep(memory, 8)) else: $typ.width
    var index = ctx.value(i.val2)
    if storageWidth(i.val2.type) > 64: raise newException(ValueError, "wide index needs checked size conversion")
    if llvmType(i.val2.type) != "i64": index = ctx.converted(index, i.val2.type, node.Type(kind: i.val2.type.kind, width: 64))
    ctx.guard(ctx.op("icmp uge", "i64", index, length), "IndexOutOfBounds")
    let base = if typ.kind == TypeKind.Slice: ctx.load(node.Type(kind: TypeKind.Ptr), memory) else: memory
    let offset = ctx.op("mul", "i64", index, $measure(typ.elem).size)
    let pointer = ctx.fresh(); ctx.add(pointer & " = getelementptr i8, ptr " & base & ", i64 " & offset)
    ctx.put(i.dest, if i.op == "address": pointer else: ctx.load(t, pointer))
  of InstrKind.Jump: ctx.transfer(i.label, i.args)
  of InstrKind.Cjump:
    let condition = ctx.op("icmp ne", "i8", ctx.value(i.cond), "0")
    let yes = "edgeTrue" & $ctx.serial; let no = "edgeFalse" & $ctx.serial
    ctx.add("br i1 " & condition & ", label %" & yes & ", label %" & no)
    ctx.mark(yes); ctx.transfer(i.trueLabel, i.trueArgs)
    ctx.mark(no); ctx.transfer(i.falseLabel, i.falseArgs)
  of InstrKind.Return: ctx.returned(i.value)
  of InstrKind.Try:
    let typ = i.expr.type
    if ctx.fn.ret.kind notin {TypeKind.Failable, TypeKind.Void}: raise newException(ValueError, "try requires a failable function")
    let memory = ctx.boxed(typ, ctx.value(i.expr))
    let errorType = node.Type(kind: TypeKind.Error); let error = ctx.load(errorType, memory)
    let failed = ctx.op("icmp ne", "ptr", error, "null")
    let failure = "tryFailure" & $ctx.serial; let success = "trySuccess" & $ctx.serial
    ctx.add("br i1 " & failed & ", label %" & failure & ", label %" & success); ctx.mark(failure)
    ctx.cleanup("true")
    if ctx.fn.ret.kind == TypeKind.Void:
      ctx.add("call void @foo_llvm_panic(ptr " & error & ")"); ctx.add("unreachable")
    else:
      let returned = ctx.temporary(ctx.fn.ret)
      ctx.store(ctx.fn.ret, "zeroinitializer", returned); ctx.store(errorType, error, returned)
      ctx.add("ret " & llvmType(ctx.fn.ret) & " " & ctx.load(ctx.fn.ret, returned))
    ctx.mark(success); ctx.put(i.dest, ctx.load(t, ctx.gep(memory, measure(typ).offsets[1])))
  of InstrKind.Catch:
    let memory = ctx.boxed(i.val.type, ctx.value(i.val))
    let failed = ctx.op("icmp ne", "ptr", ctx.load(node.Type(kind: TypeKind.Error), memory), "null")
    let fallback = "fallback" & $ctx.serial; let success = "caught" & $ctx.serial; let done = "catchDone" & $ctx.serial
    ctx.add("br i1 " & failed & ", label %" & fallback & ", label %" & success); ctx.mark(fallback)
    for child in i.fallback.instrs: ctx.instruction(child)
    if t != nil and t.kind != TypeKind.Void: ctx.put(i.dest, ctx.assign(t, i.fallback.term.value))
    ctx.add("br label %" & done); ctx.mark(success)
    ctx.put(i.dest, ctx.load(t, ctx.gep(memory, measure(i.val.type).offsets[1])))
    ctx.add("br label %" & done); ctx.mark(done)
  of InstrKind.Defer:
    let flag = ctx.slot(1, 1); ctx.prologue.add("  store i1 false, ptr " & flag & ", align 1")
    ctx.cleanups.add((i.fallback, flag, i.error)); ctx.add("store i1 true, ptr " & flag & ", align 1")
  of InstrKind.Region:
    if not ctx.regions.hasKey(i.region):
      ctx.regions[i.region] = ctx.slot(8, 8); ctx.prologue.add("  store ptr null, ptr " & ctx.regions[i.region] & ", align 1")
    if i.op == "open": ctx.add("store ptr null, ptr " & ctx.regions[i.region] & ", align 1")
    else: ctx.add("call void @foo_llvm_close(ptr " & ctx.regions[i.region] & ")")
  of InstrKind.Allocate:
    if i.target.type != nil: raise newException(ValueError, "explicit allocator allocation needs a qualified runtime adapter")
    if not ctx.regions.hasKey(i.region):
      ctx.regions[i.region] = ctx.slot(8, 8); ctx.prologue.add("  store ptr null, ptr " & ctx.regions[i.region] & ", align 1")
    let size = ctx.assign(node.Type(kind: i.val.type.kind, width: 64), i.val)
    let valid = if i.val.type.kind == TypeKind.Int: ctx.op("icmp sge", "i64", size, "0") else: "true"
    let memory = ctx.registers[i.dest.name]; ctx.store(t, "zeroinitializer", memory)
    let invalid = "allocInvalid" & $ctx.serial; let allocate = "allocValid" & $ctx.serial; let done = "allocDone" & $ctx.serial
    ctx.add("br i1 " & valid & ", label %" & allocate & ", label %" & invalid); ctx.mark(invalid)
    ctx.add("store ptr " & ctx.state.literal("InvalidSize") & ", ptr " & memory & ", align 1"); ctx.add("br label %" & done); ctx.mark(allocate)
    let pointer = ctx.fresh(); ctx.add(pointer & " = call ptr @foo_llvm_reserve(ptr " & ctx.regions[i.region] & ", i64 " & size & ")")
    let missing = ctx.op("icmp eq", "ptr", pointer, "null"); let error = ctx.fresh()
    ctx.add(error & " = select i1 " & missing & ", ptr " & ctx.state.literal("OutOfMemory") & ", ptr null")
    ctx.add("store ptr " & error & ", ptr " & memory & ", align 1")
    let payload = ctx.gep(memory, measure(t).offsets[1])
    ctx.add("store ptr " & pointer & ", ptr " & payload & ", align 1")
    ctx.add("store i64 " & size & ", ptr " & ctx.gep(payload, 8) & ", align 1")
    ctx.add("br label %" & done); ctx.mark(done)
  of InstrKind.Trace: ctx.add("call void @foo_llvm_trace(ptr " & ctx.state.literal(i.trace) & ", ptr " & ctx.state.literal(i.span.file) & ", i64 " & $i.span.start & ")")
  of InstrKind.Panic:
    if not ctx.state.hosted:
      ctx.add("call void @llvm.trap()"); ctx.add("unreachable"); return
    ctx.add("call void @foo_llvm_trace(ptr " & ctx.state.literal(ctx.fn.name) & ", ptr " & ctx.state.literal(i.span.file) & ", i64 " & $i.span.start & ")")
    ctx.add("call void @foo_llvm_panic(ptr " & ctx.state.literal(i.msg) & ")"); ctx.add("unreachable")
  of InstrKind.Reflect:
    let memory = ctx.registers[i.dest.name]; ctx.store(t, "zeroinitializer", memory)
    let measured = measure(i.typeArg); var index = 0
    for field, typ in t.fields:
      let text = case field
        of "size": $measured.size
        of "alignment": $measured.alignment
        of "name", "kind":
          let name = if field == "name": i.typeArg.label else: node.Type(kind: i.typeArg.kind).label
          ctx.value(Value(kind: ValueKind.Const, name: node.quoted(name.toOpenArrayByte(0, name.high)), type: typ))
        else: raise newException(ValueError, "unknown reflection field " & field)
      ctx.store(typ, text, ctx.gep(memory, measure(t).offsets[index])); inc index
  of InstrKind.Embed:
    let data = readFile(parentDir(ctx.state.source) / i.path)
    ctx.put(i.dest, ctx.value(Value(kind: ValueKind.Const, name: node.quoted(data.toOpenArrayByte(0, data.high)), type: t)))
  else: raise newException(ValueError, "unsupported instruction " & $i.kind)

proc emit*(module: Module; triple, layout: string; source = "main.iv"; hosted = true; cpu = ""): string =
  let profile = targetArch.profile(triple, cpu)
  let state = State(externs: initTable[string, Extern](), intrinsics: initHashSet[string](), source: source, hosted: hosted,
    contracts: initTable[string, NativeContract](), machineFunctions: initHashSet[string]())
  for fn in module.funcs:
    if fn.attributes.anyIt(it in ["naked", "interrupt", "start"]): state.machineFunctions.incl(fn.name)
  for contract in module.native:
    if contract.stage != "@asm": raise newException(ValueError, "unlowered native contract " & contract.id)
    state.contracts[contract.id] = contract
  for external in module.externs:
    state.externs[external.name] = external
    state.declarations.add("declare void @" & callbackName(external.name) & "(...)")
    state.declarations.add("declare void @" & bridgeName(external.name) & "(" & newSeqWith(external.params.len + 1, "ptr").join(", ") & ")")
  for storage in module.storage:
    let t = storage.value.type
    if aggregate(t) or t.kind notin {TypeKind.Int, TypeKind.Uint, TypeKind.Bool, TypeKind.Ptr}: raise newException(ValueError, "global initializer not qualified: " & storage.name)
    let text = if t.kind == TypeKind.Bool: (if storage.value.name == "true": "1" else: "0")
      elif t.kind == TypeKind.Ptr: "null" elif storage.value.bits.len > 0: storage.value.bits else: storage.value.name
    state.globals.add(symbol(storage.name) & " = global " & llvmType(t) & " " & text & ", align " & $measure(t).alignment)
  var entry: Function
  for fn in module.funcs:
    if fn.name == "main": entry = fn
    if fn.typeParams.len > 0: raise newException(ValueError, "generic function must be specialized by IR prepare: " & fn.name)
    discard convention(fn.abi)
    var featureAttributes: seq[string]
    for attribute in fn.attributes:
      if attribute.startsWith("target_feature(\"") and attribute.endsWith("\")"):
        let feature = attribute[16 ..< attribute.len - 2]
        if feature.len == 0 or feature.anyIt(not (it.isLowerAscii or it.isDigit or it == '_')):
          raise newException(ValueError, "invalid target feature on " & fn.name)
        let normalized = feature.replace('_', '.')
        if normalized notin profile.features:
          raise newException(ValueError, "CPU feature " & feature & " is not enabled for " & profile.cpu & " in " & fn.name)
        if "interrupt" in fn.attributes:
          raise newException(ValueError, "x64 interrupt feature clauses need a separately verified register-preservation contract: " & fn.name)
        featureAttributes.add("+" & normalized)
    let featureClause = if featureAttributes.len > 0: " \"target-features\"=" & llvmString(featureAttributes.join(",")) else: ""
    if "start" in fn.attributes:
      if hosted: raise newException(ValueError, "startup requires runtime none: " & fn.name)
      state.globals.add("@_start = alias " & llvmType(fn.ret) & " (" & fn.params.mapIt(llvmType(it.type)).join(", ") & "), ptr " & symbol(fn.name))
    if "naked" in fn.attributes:
      if fn.params.len > 0 or fn.ret.kind != TypeKind.Void or fn.blocks.len != 1:
        raise newException(ValueError, "setup-free bodies require a parameterless unit function and one native block: " & fn.name)
      var lines: seq[string]
      for instruction in fn.blocks[0].instrs:
        if instruction.kind != InstrKind.Native or instruction.args.len > 0 or not state.contracts.hasKey(instruction.symbol):
          raise newException(ValueError, "setup-free body may contain only direct assembly, never helper calls: " & fn.name)
        let contract = state.contracts[instruction.symbol]
        var assembly = contract.code.strip()
        if assembly.startsWith("\""):
          try: assembly = parseJson(assembly).getStr()
          except CatchableError: raise newException(ValueError, "setup-free assembly cannot contain C constraints or output bindings: " & fn.name)
        assembly = assembly.replace("$", "$$")
        lines.add("  call void asm sideeffect " & llvmString(assembly) & ", \"~{memory}\"()")
      if fn.blocks[0].term.kind != InstrKind.Return:
        raise newException(ValueError, "setup-free control flow must be owned by assembly: " & fn.name)
      lines.add("  unreachable")
      state.functions.add("define " & llvmType(fn.ret) & " " & symbol(fn.name) & "() naked noinline" & featureClause & " {\nentry:\n" & lines.join("\n") & "\n}")
      continue
    if "interrupt" in fn.attributes:
      if not triple.startsWith("x86_64-") or fn.ret.kind != TypeKind.Void or fn.params.len > 1 or
          (fn.params.len == 1 and llvmType(fn.params[0].type) != "i64"):
        raise newException(ValueError, "qualified x64 interrupt ABI requires unit result and optional 64-bit error code: " & fn.name)
      state.globals.add("@" & llvmString(fn.name) & " = alias void (ptr" &
        (if fn.params.len == 1: ", i64" else: "") & "), ptr " & symbol(fn.name))
    state.declarations.add("declare void @" & callbackName(fn.name) & "(...)")
    let ctx = Context(state: state, fn: fn, registers: initTable[string, string](), cells: initTable[string, string](), regions: initTable[string, string](), blocks: initTable[string, Block]())
    proc register(v: Value) =
      if v.kind == ValueKind.Reg and v.type != nil and v.type.kind notin {TypeKind.Void, TypeKind.Memory, TypeKind.Region, TypeKind.Trace} and not ctx.registers.hasKey(v.name): ctx.registers[v.name] = ctx.temporary(v.type)
    proc collect(i: Instruction) =
      if i == nil: return
      register(i.dest)
      if i.fallback != nil:
        for child in i.fallback.instrs: collect(child)
    var parameters: seq[string]
    for index, parameter in fn.params:
      register(parameter); parameters.add(llvmType(parameter.type) & " %arg" & $index)
      ctx.prologue.add("  store " & llvmType(parameter.type) & " %arg" & $index & ", ptr " & ctx.registers[parameter.name] & ", align 1")
    if "interrupt" in fn.attributes: parameters.insert("ptr byval([5 x i64]) align 8 %interrupt_frame", 0)
    for basicBlock in fn.blocks:
      ctx.blocks[basicBlock.label] = basicBlock
      for parameter in basicBlock.params: register(parameter)
      for i in basicBlock.instrs: collect(i)
      collect(basicBlock.term)
    if fn.blocks.len == 0: raise newException(ValueError, "function has no blocks " & fn.name)
    for basicBlock in fn.blocks:
      ctx.current = basicBlock.label; ctx.mark(label(basicBlock.label))
      for i in basicBlock.instrs & @[basicBlock.term]:
        try: ctx.instruction(i)
        except ValueError as error:
          raise newException(ValueError, i.span.file & ":" & $i.span.start & ".." & $i.span.end & " (source offsets) in " & fn.name & ": LLVM " & error.msg)
    # FOO's shared proof/budget owns call-boundary elimination. A pure IR
    # operation can still introduce runtime calls in this lowering (e.g. an
    # aggregate comparison), so metadata also requires call-free lowering.
    let attributes = " noinline" & (if pureFunction(fn) and
      not ctx.lines.anyIt(it.contains("call ")): " memory(none)" else: "")
    state.functions.add("define " & (if "interrupt" in fn.attributes: "x86_intrcc " else: "") & llvmType(fn.ret) & " " & symbol(fn.name) & "(" & parameters.join(", ") & ")" & attributes &
      (if "interrupt" in fn.attributes: " \"target-features\"=\"-sse,-sse2,-mmx\"" else: featureClause) & " {\nprologue:\n" & ctx.prologue.join("\n") & "\n  br label %" & label(fn.blocks[0].label) & "\n" & ctx.lines.join("\n") & "\n}")
    if "interrupt" in fn.attributes: continue
    var gateParameters = @["ptr %out"]
    var gateLines, gateArgs: seq[string]
    for index, parameter in fn.params:
      let typ = llvmType(parameter.type)
      gateParameters.add("ptr %p" & $index)
      gateLines.add("  %v" & $index & " = load " & typ & ", ptr %p" & $index & ", align 1")
      gateArgs.add(typ & " %v" & $index)
    let returns = fn.ret != nil and fn.ret.kind != TypeKind.Void
    gateLines.add("  " & (if returns: "%result = " else: "") & "call " & llvmType(fn.ret) & " " & symbol(fn.name) & "(" & gateArgs.join(", ") & ")")
    if returns: gateLines.add("  store " & llvmType(fn.ret) & " %result, ptr %out, align 1")
    gateLines.add("  ret void")
    state.functions.add("define void @" & gateName(fn.name) & "(" & gateParameters.join(", ") & ") {\nentry:\n" & gateLines.join("\n") & "\n}")
  if entry == nil and hosted: raise newException(ValueError, "LLVM executable requires an entry point")
  if entry != nil:
    if entry.params.len > 0: raise newException(ValueError, "entry must be parameterless")
    let ty = llvmType(entry.ret); var main = "define i32 @main(i32 %argc, ptr %argv) {\nentry:\n  call void @foo_llvm_init(i32 %argc, ptr %argv)\n"
    if ty == "void": main.add("  call void " & symbol(entry.name) & "()\n  call void @foo_llvm_finish(ptr null)\n  ret i32 0\n")
    elif entry.ret.kind == TypeKind.Failable:
      main.add("  %result = call " & ty & " " & symbol(entry.name) & "()\n  %memory = alloca " & ty & "\n  store " & ty & " %result, ptr %memory, align 1\n  %error = load ptr, ptr %memory, align 1\n  call void @foo_llvm_finish(ptr %error)\n  %failed = icmp ne ptr %error, null\n  %status = zext i1 %failed to i32\n  ret i32 %status\n")
    elif entry.ret.kind in {TypeKind.Int, TypeKind.Uint}:
      main.add("  %result = call " & ty & " " & symbol(entry.name) & "()\n  call void @foo_llvm_finish(ptr null)\n")
      if ty == "i32": main.add("  ret i32 %result\n")
      else: main.add("  %exit = " & (if storageWidth(entry.ret) > 32: "trunc" elif entry.ret.kind == TypeKind.Int: "sext" else: "zext") & " " & ty & " %result to i32\n  ret i32 %exit\n")
    else: raise newException(ValueError, "entry result must be unit, failable or integer")
    if not hosted:
      main = main.replace("  call void @foo_llvm_init(i32 %argc, ptr %argv)\n", "").replace("  call void @foo_llvm_finish(ptr null)\n", "").replace("  call void @foo_llvm_finish(ptr %error)\n", "")
    state.functions.add(main & "}")
  var intrinsicNames = toSeq(state.intrinsics); intrinsicNames.sort()
  for intrinsic in intrinsicNames:
    if intrinsic.startsWith("indirect:"):
      let parts = intrinsic.split(':')
      state.declarations.add("declare void @" & parts[1] & "(" & newSeqWith(parseInt(parts[2]), "ptr").join(", ") & ")")
    elif intrinsic.startsWith("compare:"): state.declarations.add("declare i8 @" & intrinsic[8..^1] & "(ptr, ptr)")
    else:
      let ty = intrinsic.split('.')[^1]; state.declarations.add("declare { " & ty & ", i1 } @" & intrinsic & "(" & ty & ", " & ty & ")")
  result = "; FOO LLVM backend\ntarget triple = " & escape(triple) & "\ntarget datalayout = " & escape(layout) & "\n" & state.globals.join("\n") & "\n" & state.declarations.join("\n") & "\n" & """
declare void @foo_llvm_panic(ptr)
declare void @foo_llvm_trace(ptr, ptr, i64)
declare void @foo_llvm_finish(ptr)
declare void @foo_llvm_init(i32, ptr)
declare void @foo_llvm_close(ptr)
declare ptr @foo_llvm_reserve(ptr, i64)
declare ptr @foo_llvm_alloc(i64)
declare void @foo_llvm_join(ptr, ptr, ptr)
declare void @free(ptr)
declare void @llvm.trap()
""" & state.functions.join("\n") & "\n"
