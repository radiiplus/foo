import std/[json, strutils, tables]
import ../../src/ir/[kind, node, print]

let integer = `Type`(kind: Shape.Int, width: 64)
let register = Value(kind: Flavor.Reg, name: "1", `type`: integer)
let constant = Value(kind: Flavor.Const, name: "41", `type`: integer)
let add = Instruction(kind: Opcode.Add, dest: register, val: constant,
  val2: Value(kind: Flavor.Const, name: "1", `type`: integer))
let finish = Instruction(kind: Opcode.Return, value: register)
let function = Function(name: "main", params: @[], ret: integer,
  blocks: @[Block(label: "entry", instrs: @[add], term: finish)])

let legacy = Module(name: "sample", funcs: @[function])
let listing = print(legacy)
doAssert listing.contains("module sample")
doAssert listing.contains("%1 = add 41, 1")
doAssert listing.contains("return %1")

let interchange = Module(name: "sample", version: 1, stage: "@foo",
  funcs: @[function])
let encoded = encode(interchange).parseJson
doAssert encoded["format"].getStr == "foo.ir"
doAssert encoded["version"].getInt == 1
doAssert encoded["functions"][0]["name"].getStr == "main"
doAssert encoded["constants"].len == 2

let memory = `Type`(kind: Shape.Memory)
let effect = Instruction(kind: Opcode.Call, `func`: "write",
  args: @[constant], effects: @["write"], memory: Memory(input: "$memory0", output: "$memory1"),
  span: Location(file: "main.iv", start: 3, `end`: 9))
let rich = Module(name: "sample", version: 1, stage: "@foo",
  package: "pkg", path: "src/main.iv", requires: "system",
  target: {"os": "linux", "arch": "x86_64"}.toTable,
  storage: @[Storage(name: "counter", public: true, value: constant)],
  regions: @[Region(id: "main.scope", kind: "scope")],
  traces: @[Trace(id: "main.trace", `function`: "main")],
  native: @[Contract(id: "native0", stage: "@c", code: "x", abi: "foo:1", effects: @["unknown"])],
  residue: @[Residue(id: "residue0", operation: "eval", state: "pending", payload: "x")],
  externs: @[Extern(name: "write", params: @[integer], ret: `Type`(kind: Shape.Void), abi: "c")],
  funcs: @[Function(name: "main", params: @[], ret: `Type`(kind: Shape.Void),
    blocks: @[Block(label: "entry", params: @[Value(kind: Flavor.Reg, name: "$memory0", `type`: memory)],
      instrs: @[effect], term: Instruction(kind: Opcode.Return, memory: Memory(input: "$memory1")))])])
let complete = encode(rich).parseJson
doAssert complete["unit"]["package"].getStr == "pkg"
doAssert complete["target"]["os"].getStr == "linux"
doAssert complete["storage"].len == 1
doAssert complete["regions"].len == 1
doAssert complete["traces"].len == 1
doAssert complete["native"].len == 1
doAssert complete["residue"].len == 1
let serialized = complete["functions"][0]["blocks"][0]["instructions"][0]["attributes"]
doAssert serialized["effects"][0].getStr == "write"
doAssert serialized["memory"]["input"].getStr == "$memory0"
doAssert serialized["span"]["file"].getStr == "main.iv"

echo "IR print parity: ok"
