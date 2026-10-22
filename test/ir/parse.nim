import std/tables
import ../../src/ir/[node, parse, print, valid, monomorph]
import ../../src/ir/kind

let integer = `Type`(kind: Shape.Int, width: 64)
let function = Function(name: "main", params: @[], ret: integer,
  blocks: @[Block(label: "entry", instrs: @[], term: Instruction(kind: Opcode.Return,
    value: Value(kind: Flavor.Const, name: "0", `type`: integer)))])
let source = print(Module(name: "sample", funcs: @[function]))
let parsed = parse(source)
doAssert parsed.name == "sample"
doAssert parsed.funcs.len == 1
doAssert parsed.funcs[0].blocks[0].term.kind == Opcode.Return
doAssert print(parsed) == source

let graph = Module(name: "fallback-graph", version: 1, stage: "@foo",
  funcs: @[Function(name: "main", ret: integer, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Defer,
        fallback: Block(label: "cleanup_entry", term:
          Instruction(kind: Opcode.Jump, label: "cleanup_exit")),
        fallbackBlocks: @[Block(label: "cleanup_exit", term:
          Instruction(kind: Opcode.Return))])],
      term: Instruction(kind: Opcode.Return,
        value: Value(kind: Flavor.Const, name: "0", `type`: integer)))])])
discard seal(graph)
let graphRoundtrip = decode(encode(graph))
let graphCleanup = graphRoundtrip.funcs[0].blocks[0].instrs[0]
doAssert graphCleanup.fallback.term.label == "cleanup_exit"
doAssert graphCleanup.fallbackBlocks.len == 1
doAssert graphCleanup.fallbackBlocks[0].term.kind == Opcode.Return
doAssert monomorph.copy(graphRoundtrip).funcs[0].blocks[0].instrs[0].
  fallbackBlocks[0].label == "cleanup_exit"

let arithmetic = parse("module math { fn @sum(%a: int64) -> int64 { entry: %b = add %a, 2 return %b } }")
doAssert arithmetic.funcs[0].blocks[0].instrs[0].dest.type.kind == Shape.Int
doAssert arithmetic.funcs[0].blocks[0].instrs[0].dest.type.width == 64

let bitwise = parse("module bits { fn @test(%a: int64) -> int64 { entry: %b = bit shl %a, 2 return %b } }")
doAssert bitwise.funcs[0].blocks[0].instrs[0].kind == Opcode.Bit
doAssert bitwise.funcs[0].blocks[0].instrs[0].op == "shl"
bitwise.version = 1
bitwise.stage = "@foo"
discard seal(bitwise)
let bitRoundtrip = decode(encode(bitwise)).funcs[0].blocks[0].instrs[0]
doAssert bitRoundtrip.kind == Opcode.Bit
doAssert bitRoundtrip.op == "shl"
doAssert bitRoundtrip.val.name == "a"
doAssert bitRoundtrip.val2.name == "2"

let encoded = encode(Module(name: "sample", version: 1, stage: "@foo", funcs: @[function]))
let restored = decode(encoded)
doAssert restored.name == "sample"
doAssert restored.version == 1
doAssert restored.funcs.len == 1

let record = `Type`(kind: Shape.Struct,
  fields: toOrderedTable({"count": `Type`(kind: Shape.Int, width: 32)}))
let aggregateBits = "07000000"
let aggregateModule = Module(name: "aggregate", version: 1, stage: "@foo",
  storage: @[Storage(name: "record", value: Value(kind: Flavor.Const,
    bits: aggregateBits, `type`: record))], funcs: @[function])
let aggregateRestored = decode(encode(aggregateModule))
doAssert aggregateRestored.storage[0].value.bits == aggregateBits
doAssert aggregateRestored.storage[0].value.type.kind == Shape.Struct

let decimal = `Type`(kind: Shape.Float, width: 64)
let lanes = `Type`(kind: Shape.Vector, width: 4, elem: decimal)
let offsets = `Type`(kind: Shape.Vector, width: 4,
  elem: `Type`(kind: Shape.Uint, width: 64))
let base = Value(kind: Flavor.Reg, name: "source", `type`: lanes)
let indices = Value(kind: Flavor.Reg, name: "indices", `type`: offsets)
let values = Value(kind: Flavor.Reg, name: "values", `type`: lanes)
let gathered = Value(kind: Flavor.Reg, name: "gathered", `type`: lanes)
let scattered = Value(kind: Flavor.Reg, name: "scattered", `type`: lanes)
let vectors = Module(name: "vectors", version: 1, stage: "@foo", funcs: @[
  Function(name: "lanes", params: @[base, indices, values], ret: lanes,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Gather, dest: gathered, val: base,
        val2: indices),
      Instruction(kind: Opcode.Scatter, dest: scattered, val: gathered,
        val2: indices, args: @[values])],
      term: Instruction(kind: Opcode.Return, value: scattered))])])
discard seal(vectors)
let reconstructed = decode(encode(vectors))
doAssert reconstructed.funcs[0].blocks[0].instrs[0].kind == Opcode.Gather
doAssert reconstructed.funcs[0].blocks[0].instrs[1].kind == Opcode.Scatter
doAssert reconstructed.funcs[0].blocks[0].instrs[1].args[0].name == "values"

let memory = `Type`(kind: Shape.Memory)
let unit = `Type`(kind: Shape.Void)
let rich = Module(name: "pkg", version: 1, stage: "@foo", package: "pkg",
  path: "src/main.iv", requires: "system", target: {"os": "linux"}.toTable,
  regions: @[Region(id: "main.scope", kind: "scope")],
  traces: @[Trace(id: "main.trace", `function`: "main")],
  native: @[Contract(id: "native0", stage: "@c", code: "x", abi: "foo:1", effects: @["unknown"])],
  residue: @[Residue(id: "residue0", operation: "eval", state: "pending", payload: "x")],
  externs: @[Extern(name: "write", params: @[integer], ret: unit, abi: "c")],
  funcs: @[Function(name: "main", params: @[], ret: unit,
    blocks: @[Block(label: "entry", params: @[Value(kind: Flavor.Reg, name: "$memory0", `type`: memory)],
      instrs: @[Instruction(kind: Opcode.Call, `func`: "write", args: @[Value(kind: Flavor.Const, name: "1", `type`: integer)],
        effects: @["write"], memory: Memory(input: "$memory0", output: "$memory1"))],
      term: Instruction(kind: Opcode.Return, memory: Memory(input: "$memory1")))])])
let trip = decode(encode(rich))
doAssert trip.path == "src/main.iv"
doAssert trip.target["os"] == "linux"
doAssert trip.regions[0].id == "main.scope"
doAssert trip.traces[0].id == "main.trace"
doAssert trip.native[0].effects == @["unknown"]
doAssert trip.residue[0].operation == "eval"
doAssert trip.funcs[0].blocks[0].instrs[0].effects == @["write"]
doAssert trip.funcs[0].blocks[0].instrs[0].memory.output == "$memory1"

echo "IR parse parity: ok"
