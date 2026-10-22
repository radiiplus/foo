import std/[json, os, osproc]
import ../../../../src/backend/qbe/driver
import ../../../../src/build/options
import ../../../../src/ir/[kind, node]

let integer = `Type`(kind: Shape.Int, width: 32)
let input = Value(kind: Flavor.Reg, name: "input", `type`: integer)
let resultValue = Value(kind: Flavor.Reg, name: "result", `type`: integer)
let exported = Function(name: "qbe_export_vectorcall", public: true,
  abi: "vectorcall", params: @[input], ret: integer,
  blocks: @[Block(label: "entry", term:
    Instruction(kind: Opcode.Return, value: input))])
let main = Function(name: "main", ret: integer,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, `func`: "qbe_export_vectorcall",
      args: @[Value(kind: Flavor.Const, name: "41", `type`: integer)],
      dest: resultValue)],
    term: Instruction(kind: Opcode.Return, value: resultValue))])
let module = Module(funcs: @[exported, main])

if getEnv("FOO_QBE").len > 0 and getEnv("FOO_QBE_TCC").len > 0:
  let built = build(module, "dev", ".artifacts/qbe-driver-abi-test",
    Native(name: "abi", kind: "exe", target: "windows-x64"))
  doAssert built.success, built.error
  let executed = execCmdEx(quoteShell(built.artifact))
  doAssert executed.exitCode == 41, executed.output
  let metadata = parseFile(built.artifact & ".qbe.json")
  doAssert metadata["cc"]["sha256"].getStr().len == 64
  doAssert metadata["policy"].getStr() == "qbe-freestanding-memory-v10"

echo "QBE Windows ABI driver probe: ok"
