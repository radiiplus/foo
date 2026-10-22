import ../../src/ir/[kind, node, reach]

let representation = `Type`(kind: Shape.Void)
let unused = Function(name: "unused", ret: representation,
  blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return))])
let helper = Function(name: "helper", ret: representation,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, `func`: "output")],
    term: Instruction(kind: Opcode.Return))])
let main = Function(name: "main", ret: representation,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, `func`: "helper")],
    term: Instruction(kind: Opcode.Return))])
let module = Module(name: "reach", funcs: @[unused, helper, main], externs: @[
  Extern(name: "output", symbol: "write", abi: "runtime.io", ret: representation),
  Extern(name: "open", abi: "runtime.fs", ret: representation)])

let selected = reach(module)
doAssert selected.funcs.len == 2
doAssert selected.funcs[0].name == "helper"
doAssert selected.funcs[1].name == "main"
doAssert selected.externs.len == 1
doAssert selected.externs[0].name == "output"

let library = reach(Module(name: "library", funcs: @[
  Function(name: "hidden", ret: representation,
    blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return))]),
  Function(name: "visible", public: true, ret: representation,
    blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return))])],
  storage: @[Storage(name: "callback", public: true,
    value: Value(kind: Flavor.Global, name: "hidden"))]), true)
doAssert library.funcs.len == 2
doAssert library.storage.len == 1

echo "IR reachability: ok"
