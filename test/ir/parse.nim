import std/tables
import ../../src/ir/[node, parse, print]
import ../../src/ir/kind

let integer = `Type`(kind: TypeKind.Int, width: 64)
let function = Function(name: "main", params: @[], ret: integer,
  blocks: @[Block(label: "entry", instrs: @[], term: Instruction(kind: InstrKind.Return,
    value: Value(kind: ValueKind.Const, name: "0", `type`: integer)))])
let source = print(Module(name: "sample", funcs: @[function]))
let parsed = parse(source)
doAssert parsed.name == "sample"
doAssert parsed.funcs.len == 1
doAssert parsed.funcs[0].blocks[0].term.kind == InstrKind.Return
doAssert print(parsed) == source

let arithmetic = parse("module math { fn @sum(%a: int64) -> int64 { entry: %b = add %a, 2 return %b } }")
doAssert arithmetic.funcs[0].blocks[0].instrs[0].dest.type.kind == TypeKind.Int
doAssert arithmetic.funcs[0].blocks[0].instrs[0].dest.type.width == 64

let encoded = encode(Module(name: "sample", version: 1, stage: "@foo", funcs: @[function]))
let restored = decode(encoded)
doAssert restored.name == "sample"
doAssert restored.version == 1
doAssert restored.funcs.len == 1

let memory = `Type`(kind: TypeKind.Memory)
let unit = `Type`(kind: TypeKind.Void)
let rich = Module(name: "pkg", version: 1, stage: "@foo", unitPackage: "pkg",
  unitPath: "src/main.iv", requires: "system", target: {"os": "linux"}.toTable,
  regions: @[Region(id: "main.scope", kind: "scope")],
  traces: @[Trace(id: "main.trace", `function`: "main")],
  native: @[NativeContract(id: "native0", stage: "@c", code: "x", abi: "foo:1", effects: @["unknown"])],
  residue: @[Residue(id: "residue0", operation: "eval", state: "pending", payload: "x")],
  externs: @[Extern(name: "write", params: @[integer], ret: unit, abi: "c")],
  funcs: @[Function(name: "main", params: @[], ret: unit,
    blocks: @[Block(label: "entry", params: @[Value(kind: ValueKind.Reg, name: "$memory0", `type`: memory)],
      instrs: @[Instruction(kind: InstrKind.Call, `func`: "write", args: @[Value(kind: ValueKind.Const, name: "1", `type`: integer)],
        effects: @["write"], memory: Memory(input: "$memory0", output: "$memory1"))],
      term: Instruction(kind: InstrKind.Return, memory: Memory(input: "$memory1")))])])
let roundTrip = decode(encode(rich))
doAssert roundTrip.unitPath == "src/main.iv"
doAssert roundTrip.target["os"] == "linux"
doAssert roundTrip.regions[0].id == "main.scope"
doAssert roundTrip.traces[0].id == "main.trace"
doAssert roundTrip.native[0].effects == @["unknown"]
doAssert roundTrip.residue[0].operation == "eval"
doAssert roundTrip.funcs[0].blocks[0].instrs[0].effects == @["write"]
doAssert roundTrip.funcs[0].blocks[0].instrs[0].memory.output == "$memory1"

echo "IR parse parity: ok"
