import std/[os, sequtils, sets]
import ../../src/ir/[kind, monomorph, node, print, reach, valid]
import ../../src/opt/gpu as gpuLower
import ../../src/opt/spirv as spirvCompiler
import ../../src/build/compiler

let vectorCompiler = newCompiler(getCurrentDir(), backend = "c",
  mode = "release", optimization = true, target = "x86_64-windows")
let vectorModule = vectorCompiler.ir("test/library/hints.iv")
var gpuCalls: seq[Instruction]
for function in vectorModule.funcs:
  for basicBlock in function.blocks:
    for instruction in basicBlock.instrs:
      if instruction.kind == InstrKind.Call and
          instruction.abi == "runtime.gpu" and instruction.symbol == "prepared":
        gpuCalls.add(instruction)
doAssert gpuCalls.len == 5
proc unpack(value: Value): string =
  for item in bytes(value.name): result.add(char(item))

proc word(code: string; offset: int): uint32 =
  for shift in 0 .. 3:
    result = result or (uint32(ord(code[offset + shift])) shl (shift * 8))

proc operations(code: string): HashSet[uint32] =
  doAssert code.len >= 20 and code.len mod 4 == 0
  doAssert word(code, 0) == 0x07230203'u32
  var offset = 20
  while offset < code.len:
    let header = word(code, offset)
    let count = int(header shr 16)
    doAssert count > 0 and offset + count * 4 <= code.len
    result.incl(header and 0xffff'u32)
    offset += count * 4

var kernels = initHashSet[string]()
for call in gpuCalls:
  doAssert call.args.len == 7
  let code = unpack(call.args[1])
  let name = unpack(call.args[2])
  let matches = vectorModule.funcs.filterIt(it.name == name and it.abi == "gpu")
  doAssert matches.len == 1
  doAssert code == spirvCompiler.compile(matches[0])
  let ops = operations(code)
  doAssert 15'u32 in ops and 331'u32 in ops and 54'u32 in ops
  kernels.incl(name)
  case name
  of "shade":
    doAssert 129'u32 in ops
  of "tile":
    doAssert 224'u32 in ops
    doAssert call.args[4].name == "4"
    doAssert call.args[5].name == "1"
    doAssert call.args[6].name == "16"
  of "stripe":
    doAssert 132'u32 in ops
  of "tally":
    doAssert 234'u32 in ops
    doAssert call.args[5].name == "2"
  of "wave":
    doAssert 338'u32 in ops
    doAssert call.args[5].name == "4"
  else:
    doAssert false, name
doAssert kernels == toHashSet(["shade", "tile", "stripe", "tally", "wave"])
let gpuEntry = cloneModule(vectorModule)
gpuEntry.funcs.add(Function(name: "main", ret: `Type`(kind: TypeKind.Void),
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: InstrKind.Call, `func`: "paint")],
    term: Instruction(kind: InstrKind.Return))]))
let gpuHost = reach(gpuEntry)
doAssert gpuHost.funcs.anyIt(it.name == "paint")
doAssert not gpuHost.funcs.anyIt(it.name == "shade")
var rejected = false
try:
  discard gpuLower.apply(Module(name: "host", funcs: @[
    Function(name: "main", ret: `Type`(kind: TypeKind.Void), blocks: @[
      Block(label: "entry", instrs: @[
        Instruction(kind: InstrKind.Call, abi: "runtime.gpu", symbol: "index")],
        term: Instruction(kind: InstrKind.Return))])]))
except ValueError:
  rejected = true
doAssert rejected
let captured = cloneModule(vectorModule)
captured.funcs.add(Function(name: "main", ret: `Type`(kind: TypeKind.Void),
  blocks: @[Block(label: "entry", instrs: @[],
    term: Instruction(kind: InstrKind.Return,
      value: Value(kind: ValueKind.Global, name: "shade")))]))
rejected = false
try:
  discard gpuLower.apply(captured)
except ValueError:
  rejected = true
doAssert rejected
doAssert vectorModule.optimization.vectors >= 15
doAssert vectorModule.externs.anyIt(it.abi == "runtime.cpu" and it.symbol == "vectorize")
var vectorized = initHashSet[string]()
for function in vectorModule.funcs:
  for basicBlock in function.blocks:
    if basicBlock.instrs.anyIt(it.kind == InstrKind.Call and
        it.symbol == "vectorize"):
      vectorized.incl(function.name)
for name in ["lane", "minus", "times", "quotient", "narrow", "scale",
    "bias", "fill", "mirror", "shift", "affine", "magnify", "window",
    "invert", "ratio"]:
  doAssert name in vectorized, name
doAssert "serial" notin vectorized
let parameterType = `Type`(kind: TypeKind.Struct, name: "T")
let identity = Function(name: "identity", typeParams: @["T"],
  params: @[Value(kind: ValueKind.Reg, name: "value", `type`: parameterType)],
  ret: parameterType, blocks: @[Block(label: "entry", instrs: @[],
    term: Instruction(kind: InstrKind.Return,
      value: Value(kind: ValueKind.Reg, name: "value", `type`: parameterType)))])
let integer = `Type`(kind: TypeKind.Int, width: 32)
let readonly = `Type`(kind: TypeKind.Ptr, elem: integer, constant: true)
let writable = `Type`(kind: TypeKind.Ptr, elem: integer)
let first = Instruction(kind: InstrKind.Call, `func`: "identity", typeArgs: @[readonly],
  args: @[Value(kind: ValueKind.Reg, name: "read", `type`: readonly)],
  dest: Value(kind: ValueKind.Reg, name: "a", `type`: readonly))
let second = Instruction(kind: InstrKind.Call, `func`: "identity", typeArgs: @[writable],
  args: @[Value(kind: ValueKind.Reg, name: "write", `type`: writable)],
  dest: Value(kind: ValueKind.Reg, name: "b", `type`: writable))
let main = Function(name: "main", params: @[], ret: `Type`(kind: TypeKind.Void),
  blocks: @[Block(label: "entry", instrs: @[first, second],
    term: Instruction(kind: InstrKind.Return))])
let original = Module(name: "generic", funcs: @[identity, main])
let before = print(original)
let specialized = monomorphize(original)
doAssert print(original) == before
doAssert specialized.funcs.len == 3
doAssert specialized.optimization.generics == 2
doAssert specialized.funcs[0].blocks[0].instrs[0].func != specialized.funcs[0].blocks[0].instrs[1].func
doAssert specialized.funcs[1].params[0].type.constant
doAssert not specialized.funcs[2].params[0].type.constant

let externalCall = Instruction(kind: InstrKind.Call, `func`: "runtime_create",
  typeArgs: @[integer], dest: Value(kind: ValueKind.Reg, name: "created",
    `type`: `Type`(kind: TypeKind.Slice, elem: integer)))
let externalModule = monomorphize(Module(name: "external", externs: @[
  Extern(name: "runtime_create", symbol: "create", abi: "runtime.sequence",
    typeParams: @["T"], ret: `Type`(kind: TypeKind.Slice,
      elem: `Type`(kind: TypeKind.Struct, name: "T")))], funcs: @[
  Function(name: "main", ret: `Type`(kind: TypeKind.Void), blocks: @[
    Block(label: "entry", instrs: @[externalCall],
      term: Instruction(kind: InstrKind.Return))])]))
doAssert externalModule.externs.len == 1
doAssert externalModule.externs[0].typeParams.len == 0
doAssert externalModule.externs[0].ret.elem.kind == TypeKind.Int
doAssert externalModule.funcs[0].blocks[0].instrs[0].func ==
  externalModule.externs[0].name

let floatType = `Type`(kind: TypeKind.Float, width: 64)
let repeated = Module(name: "repeat", funcs: @[Function(name: "main", ret: floatType,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: InstrKind.Add, dest: Value(kind: ValueKind.Reg, name: "one", `type`: floatType),
      val: Value(kind: ValueKind.Const, name: "1.0", `type`: floatType), val2: Value(kind: ValueKind.Const, name: "2.0", `type`: floatType)),
    Instruction(kind: InstrKind.Add, dest: Value(kind: ValueKind.Reg, name: "two", `type`: floatType),
      val: Value(kind: ValueKind.Const, name: "1.0", `type`: floatType), val2: Value(kind: ValueKind.Const, name: "2.0", `type`: floatType))
  ], term: Instruction(kind: InstrKind.Return,
    value: Value(kind: ValueKind.Reg, name: "two", `type`: floatType)))])])
let optimized = optimize(repeated)
doAssert optimized.expressions == 1
doAssert optimized.module.funcs[0].blocks[0].instrs.len == 1

let scalar = `Type`(kind: TypeKind.Float, width: 64)
proc pureAdd(name, resultName: string): Function =
  Function(name: name, params: @[
    Value(kind: ValueKind.Reg, name: "left", `type`: scalar),
    Value(kind: ValueKind.Reg, name: "right", `type`: scalar)], ret: scalar,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: InstrKind.Add,
        dest: Value(kind: ValueKind.Reg, name: resultName, `type`: scalar),
        val: Value(kind: ValueKind.Reg, name: "left", `type`: scalar),
        val2: Value(kind: ValueKind.Reg, name: "right", `type`: scalar))],
      term: Instruction(kind: InstrKind.Return,
        value: Value(kind: ValueKind.Reg, name: resultName, `type`: scalar)))])

let firstAdd = pureAdd("firstAdd", "firstResult")
let secondAdd = pureAdd("secondAdd", "otherResult")
let callAdd = Instruction(kind: InstrKind.Call, `func`: "secondAdd", args: @[
  Value(kind: ValueKind.Const, name: "20.0", `type`: scalar),
  Value(kind: ValueKind.Const, name: "22.0", `type`: scalar)],
  dest: Value(kind: ValueKind.Reg, name: "answer", `type`: scalar))
let optimizedCalls = optimize(Module(name: "inline", funcs: @[
  firstAdd, secondAdd,
  Function(name: "main", ret: scalar, blocks: @[
    Block(label: "entry", instrs: @[callAdd], term: Instruction(
      kind: InstrKind.Return,
      value: Value(kind: ValueKind.Reg, name: "answer", `type`: scalar)))])]),
  OptimizeOptions(inline: true, target: "linux-x64", cpu: "x86-64"))
doAssert optimizedCalls.functions == 1
doAssert optimizedCalls.inlined == 1
doAssert optimizedCalls.module.optimization.inlined == 1
doAssert optimizedCalls.module.funcs.len == 2
doAssert optimizedCalls.module.funcs[1].blocks[0].instrs.len == 1
doAssert optimizedCalls.module.funcs[1].blocks[0].instrs[0].kind == InstrKind.Add
doAssert optimizedCalls.module.funcs[1].blocks[0].term.value.name == "answer"
doAssert validate(optimizedCalls.module).len == 0

let pointer = `Type`(kind: TypeKind.Ptr, elem: integer)
let promoted = optimize(Module(name: "storage", funcs: @[
  Function(name: "main", ret: integer, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: InstrKind.Alloc, op: "slot",
        dest: Value(kind: ValueKind.Reg, name: "cell", `type`: pointer)),
      Instruction(kind: InstrKind.Store,
        `ptr`: Value(kind: ValueKind.Reg, name: "cell", `type`: pointer),
        val: Value(kind: ValueKind.Const, name: "41", `type`: integer)),
      Instruction(kind: InstrKind.Load,
        dest: Value(kind: ValueKind.Reg, name: "loaded", `type`: integer),
        `ptr`: Value(kind: ValueKind.Reg, name: "cell", `type`: pointer))],
      term: Instruction(kind: InstrKind.Return,
        value: Value(kind: ValueKind.Reg, name: "loaded", `type`: integer)))])]))
doAssert promoted.allocations == 1
doAssert promoted.module.optimization.allocations == 1
doAssert promoted.module.funcs[0].blocks[0].instrs.len == 0
doAssert promoted.module.funcs[0].blocks[0].term.value.name == "41"

let converted = optimize(Module(name: "boundary", funcs: @[
  Function(name: "main", ret: integer, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: InstrKind.Convert,
        dest: Value(kind: ValueKind.Reg, name: "converted", `type`: integer),
        val: Value(kind: ValueKind.Const, name: "7", `type`: integer))],
      term: Instruction(kind: InstrKind.Return,
        value: Value(kind: ValueKind.Reg, name: "converted", `type`: integer)))])]))
doAssert converted.boundaries == 1
doAssert converted.module.funcs[0].blocks[0].instrs.len == 0
doAssert converted.module.funcs[0].blocks[0].term.value.name == "7"

proc pureMultiply(name: string): Function =
  Function(name: name, params: @[
    Value(kind: ValueKind.Reg, name: "left", `type`: scalar),
    Value(kind: ValueKind.Reg, name: "right", `type`: scalar)], ret: scalar,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: InstrKind.Mul,
        dest: Value(kind: ValueKind.Reg, name: "product", `type`: scalar),
        val: Value(kind: ValueKind.Reg, name: "left", `type`: scalar),
        val2: Value(kind: ValueKind.Reg, name: "right", `type`: scalar))],
      term: Instruction(kind: InstrKind.Return,
        value: Value(kind: ValueKind.Reg, name: "product", `type`: scalar)))])

let fused = optimize(Module(name: "pipeline", funcs: @[
  pureAdd("sum", "sumResult"), pureMultiply("scale"),
  Function(name: "main", ret: scalar, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: InstrKind.Call, `func`: "sum", args: @[
        Value(kind: ValueKind.Const, name: "2.0", `type`: scalar),
        Value(kind: ValueKind.Const, name: "3.0", `type`: scalar)],
        dest: Value(kind: ValueKind.Reg, name: "sumValue", `type`: scalar)),
      Instruction(kind: InstrKind.Call, `func`: "scale", args: @[
        Value(kind: ValueKind.Reg, name: "sumValue", `type`: scalar),
        Value(kind: ValueKind.Const, name: "4.0", `type`: scalar)],
        dest: Value(kind: ValueKind.Reg, name: "result", `type`: scalar))],
      term: Instruction(kind: InstrKind.Return,
        value: Value(kind: ValueKind.Reg, name: "result", `type`: scalar)))])]),
  OptimizeOptions(inline: true, target: "linux-x64", cpu: "x86-64"))
doAssert fused.inlined == 2
doAssert fused.pipelines == 1
doAssert fused.module.optimization.pipelines == 1
doAssert fused.module.funcs[^1].blocks[0].instrs.len == 2

var costly: seq[Instruction]
for index in 0 ..< 24:
  costly.add(Instruction(kind: InstrKind.Add,
    dest: Value(kind: ValueKind.Reg, name: "step" & $index, `type`: scalar),
    val: if index == 0: Value(kind: ValueKind.Const, name: "1.0", `type`: scalar)
      else: Value(kind: ValueKind.Reg, name: "step" & $(index - 1), `type`: scalar),
    val2: Value(kind: ValueKind.Const, name: "1.0", `type`: scalar)))
let costlyFunction = Function(name: "costly", ret: scalar, blocks: @[
  Block(label: "entry", instrs: costly, term: Instruction(kind: InstrKind.Return,
    value: Value(kind: ValueKind.Reg, name: "step23", `type`: scalar)))])
let costlyCall = Function(name: "main", ret: scalar, blocks: @[
  Block(label: "entry", instrs: @[
    Instruction(kind: InstrKind.Call, `func`: "costly",
      dest: Value(kind: ValueKind.Reg, name: "profiled", `type`: scalar))],
    term: Instruction(kind: InstrKind.Return,
      value: Value(kind: ValueKind.Reg, name: "profiled", `type`: scalar)))])
let normalInlining = optimize(Module(name: "normal", funcs: @[
  costlyFunction, costlyCall]), OptimizeOptions(inline: true,
    target: "linux-x64", cpu: "x86-64"))
doAssert normalInlining.inlined == 0
var hotFunctions = initHashSet[string]()
hotFunctions.incl("costly")
let guidedInlining = optimize(Module(name: "guided", funcs: @[
  costlyFunction, costlyCall]), OptimizeOptions(inline: true,
    target: "linux-x64", cpu: "x86-64", hot: hotFunctions))
doAssert guidedInlining.inlined == 1

let nothing = `Type`(kind: TypeKind.Void)
let continuation = `Type`(kind: TypeKind.Function, params: @[], ret: nothing,
  abi: "c")
let direct = optimize(Module(name: "continuation", externs: @[
  Extern(name: "task_block", symbol: "block", abi: "runtime.task",
    params: @[continuation], ret: nothing)], funcs: @[
  Function(name: "worker", abi: "c", ret: nothing, blocks: @[
    Block(label: "entry", instrs: @[],
      term: Instruction(kind: InstrKind.Return))]),
  Function(name: "main", ret: nothing, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: InstrKind.Call, `func`: "task_block", args: @[
        Value(kind: ValueKind.Global, name: "worker", `type`: continuation)])],
      term: Instruction(kind: InstrKind.Return))])]))
doAssert direct.continuations == 1
doAssert direct.module.funcs[1].blocks[0].instrs[0].func == "worker"
doAssert direct.module.funcs[1].blocks[0].instrs[0].args.len == 0
doAssert direct.module.funcs[1].blocks[0].instrs[0].op ==
  "direct-continuation"

let byteType = `Type`(kind: TypeKind.Uint, width: 8)
let text = `Type`(kind: TypeKind.Slice, elem: byteType, constant: true)
let encoded = `Type`(kind: TypeKind.Failable, elem: text)
let serialization = optimize(Module(name: "serialization", externs: @[
  Extern(name: "json_quote", symbol: "quote", abi: "runtime.json",
    params: @[text], ret: encoded)], funcs: @[
  Function(name: "main", ret: encoded, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: InstrKind.Call, `func`: "json_quote", abi: "runtime.json",
        symbol: "quote", args: @[
          Value(kind: ValueKind.Const, name: "\"line\\x0aquote\\\"\"", `type`: text)],
        dest: Value(kind: ValueKind.Reg, name: "encoded", `type`: encoded))],
      term: Instruction(kind: InstrKind.Return,
        value: Value(kind: ValueKind.Reg, name: "encoded", `type`: encoded)))])]))
doAssert serialization.serializations == 1
doAssert serialization.module.funcs[0].blocks[0].instrs[0].kind ==
  InstrKind.Convert
let expectedJson = "\"line\\nquote\\\"\""
doAssert serialization.module.funcs[0].blocks[0].instrs[0].val.name ==
  quoted(expectedJson.toOpenArrayByte(0, expectedJson.high))
doAssert validate(serialization.module).len == 0

let callbackType = `Type`(kind: TypeKind.Function,
  params: @[scalar, scalar], ret: scalar)
let addressUse = Function(name: "keepsAddress", ret: callbackType,
  blocks: @[Block(label: "entry", instrs: @[], term: Instruction(
    kind: InstrKind.Return, value: Value(kind: ValueKind.Global,
      name: "firstAdd", `type`: callbackType)))])
let retainedIdentity = optimize(Module(name: "identity", funcs: @[
  pureAdd("firstAdd", "one"), pureAdd("secondAdd", "two"), addressUse]),
  OptimizeOptions(inline: true, target: "linux-x64"))
doAssert retainedIdentity.functions == 0
doAssert retainedIdentity.module.funcs.len == 3

let threaded = Instruction(kind: InstrKind.Thread, `func`: "worker", panic: "failed")
let prepared = prepare(Module(name: "prepare", funcs: @[
  Function(name: "main", ret: `Type`(kind: TypeKind.Void), blocks: @[
    Block(label: "entry", instrs: @[threaded], term: Instruction(kind: InstrKind.Return)),
    Block(label: "failed", instrs: @[], term: Instruction(kind: InstrKind.Panic, msg: "failed"))
  ])
]))
doAssert prepared.funcs[0].blocks.len == 1
doAssert prepared.funcs[0].blocks[0].instrs[0].kind == InstrKind.Call

echo "IR monomorph parity: ok"
