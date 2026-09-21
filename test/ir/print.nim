import std/[json, strutils, tables]
import ../../src/ir/[kind, node, print]

let integer = `Type`(kind: TypeKind.Int, width: 64)
let register = Value(kind: ValueKind.Reg, name: "1", `type`: integer)
let constant = Value(kind: ValueKind.Const, name: "41", `type`: integer)
let add = Instruction(kind: InstrKind.Add, dest: register, val: constant,
  val2: Value(kind: ValueKind.Const, name: "1", `type`: integer))
let finish = Instruction(kind: InstrKind.Return, value: register)
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

let memory = `Type`(kind: TypeKind.Memory)
let effect = Instruction(kind: InstrKind.Call, `func`: "write",
  args: @[constant], effects: @["write"], memory: Memory(input: "$memory0", output: "$memory1"),
  span: SourceSpan(file: "main.iv", start: 3, `end`: 9))
let rich = Module(name: "sample", version: 1, stage: "@foo",
  unitPackage: "pkg", unitPath: "src/main.iv", requires: "system",
  target: {"os": "linux", "arch": "x86_64"}.toTable,
  storage: @[Storage(name: "counter", public: true, value: constant)],
  regions: @[Region(id: "main.scope", kind: "scope")],
  traces: @[Trace(id: "main.trace", `function`: "main")],
  native: @[NativeContract(id: "native0", stage: "@c", code: "x", abi: "foo:1", effects: @["unknown"])],
  residue: @[Residue(id: "residue0", operation: "eval", state: "pending", payload: "x")],
  externs: @[Extern(name: "write", params: @[integer], ret: `Type`(kind: TypeKind.Void), abi: "c")],
  funcs: @[Function(name: "main", params: @[], ret: `Type`(kind: TypeKind.Void),
    blocks: @[Block(label: "entry", params: @[Value(kind: ValueKind.Reg, name: "$memory0", `type`: memory)],
      instrs: @[effect], term: Instruction(kind: InstrKind.Return, memory: Memory(input: "$memory1")))])])
let complete = encode(rich).parseJson
doAssert complete["unit"]["package"].getStr == "pkg"
doAssert complete["target"]["os"].getStr == "linux"
doAssert complete["storage"].len == 1
doAssert complete["regions"].len == 1
doAssert complete["traces"].len == 1
doAssert complete["native"].len == 1
doAssert complete["residue"].len == 1
let encodedEffect = complete["functions"][0]["blocks"][0]["instructions"][0]["attributes"]
doAssert encodedEffect["effects"][0].getStr == "write"
doAssert encodedEffect["memory"]["input"].getStr == "$memory0"
doAssert encodedEffect["span"]["file"].getStr == "main.iv"

echo "IR print parity: ok"
