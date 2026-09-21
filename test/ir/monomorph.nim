import ../../src/ir/[kind, monomorph, node, print]

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
