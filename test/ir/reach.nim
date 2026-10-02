import ../../src/ir/[kind, node, reach]

let unitType = `Type`(kind: TypeKind.Void)
let unused = Function(name: "unused", ret: unitType,
  blocks: @[Block(label: "entry", term: Instruction(kind: InstrKind.Return))])
let helper = Function(name: "helper", ret: unitType,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: InstrKind.Call, `func`: "output")],
    term: Instruction(kind: InstrKind.Return))])
let main = Function(name: "main", ret: unitType,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: InstrKind.Call, `func`: "helper")],
    term: Instruction(kind: InstrKind.Return))])
let module = Module(name: "reach", funcs: @[unused, helper, main], externs: @[
  Extern(name: "output", symbol: "write", abi: "runtime.io", ret: unitType),
  Extern(name: "open", abi: "runtime.fs", ret: unitType)])

let selected = reach(module)
doAssert selected.funcs.len == 2
doAssert selected.funcs[0].name == "helper"
doAssert selected.funcs[1].name == "main"
doAssert selected.externs.len == 1
doAssert selected.externs[0].name == "output"

let library = reach(Module(name: "library", funcs: @[
  Function(name: "hidden", ret: unitType,
    blocks: @[Block(label: "entry", term: Instruction(kind: InstrKind.Return))]),
  Function(name: "visible", public: true, ret: unitType,
    blocks: @[Block(label: "entry", term: Instruction(kind: InstrKind.Return))])],
  storage: @[Storage(name: "callback", public: true,
    value: Value(kind: ValueKind.Global, name: "hidden"))]), true)
doAssert library.funcs.len == 2
doAssert library.storage.len == 1

echo "IR reachability: ok"
