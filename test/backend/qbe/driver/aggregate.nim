import std/[os, osproc, tables]
import ../../../../src/backend/qbe/driver
import ../../../../src/build/options
import ../../../../src/ir/[kind, node]

let integer = `Type`(kind: Shape.Int, width: 32)
let pair = `Type`(kind: Shape.Struct,
  fields: initOrderedTable[string, `Type`]())
pair.fields["first"] = integer
pair.fields["second"] = integer
let constructed = Value(kind: Flavor.Reg, name: "constructed", `type`: pair)
let returned = Value(kind: Flavor.Reg, name: "returned", `type`: pair)
let second = Value(kind: Flavor.Reg, name: "second", `type`: integer)
let program = Module(funcs: @[Function(name: "main", ret: integer,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: constructed, args: @[
      Value(kind: Flavor.Const, name: "10", `type`: integer),
      Value(kind: Flavor.Const, name: "20", `type`: integer)]),
    Instruction(kind: Opcode.Call, `func`: "foreign_pair",
      args: @[constructed], dest: returned),
    Instruction(kind: Opcode.Extract, val: returned, field: "second",
      dest: second)],
    term: Instruction(kind: Opcode.Return, value: second))])],
  externs: @[Extern(name: "foreign_pair", symbol: "qbe_foreign_pair",
    abi: "system", params: @[pair], ret: pair)])
let target = when defined(windows): "windows-x64" else: "linux-x64"
let source = absolutePath("test/backend/qbe/driver/aggregate.c")
let settings = Native(name: "driver-aggregate", kind: "exe", target: target,
  sources: @[source])
let built = build(program, "dev", ".artifacts/qbe-driver-aggregate", settings)
doAssert built.success, built.error
doAssert execCmdEx(quoteShell(built.artifact)).exitCode == 22
let repeat = build(program, "dev", ".artifacts/qbe-driver-aggregate", settings)
doAssert repeat.success and repeat.cached, repeat.error

echo "QBE driver aggregate foreign ABI: ok"
