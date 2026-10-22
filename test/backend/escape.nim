import std/strutils
import ../../src/interop/escape
import ../../src/opt/substrate
import ../../src/ir/node
import ../../src/ir/kind

let contract = Contract(id: "hello", stage: "@c", code: "return 1;", abi: "c", effects: @[])
let module = Module(name: "demo", funcs: @[], externs: @[], native: @[contract])
let result = escape(module, Selection(target: "linux-x64", level: "system"))
doAssert result.code.contains("return 1;")
doAssert result.module.native.len == 0

let nested = Instruction(kind: Opcode.Native, symbol: "nested",
  dest: Value(`type`: `Type`(kind: Shape.Void)), args: @[])
let fallback = Block(label: "fallback", instrs: @[nested])
let entry = Block(label: "entry",
  instrs: @[Instruction(kind: Opcode.Load, fallback: fallback)])
let namespace = Module(name: "nested", funcs: @[
  Function(name: "start", blocks: @[entry])], native: @[
  Contract(id: "nested", stage: "@c",
    code: "#include <stddef.h>\nreturn;", abi: "c", effects: @[])])
let returned = escape(namespace,
  Selection(target: "linux-x64", level: "system"))
doAssert returned.module.funcs[0].blocks[0].instrs[0].fallback.instrs[0].kind == Opcode.Call
doAssert returned.module.externs.len == 1
doAssert returned.code.count("#include <stddef.h>") == 1
doAssert not returned.code.contains("// #include")

let instruction = Instruction(kind: Opcode.Native, symbol: "bootasm")
let unit = Module(name: "inline", funcs: @[
  Function(name: "boot", attributes: @["start", "naked"],
    ret: `Type`(kind: Shape.Void), blocks: @[
      Block(label: "entry", instrs: @[instruction],
        term: Instruction(kind: Opcode.Return))])], native: @[
  Contract(id: "bootasm", stage: "@asm", code: "\"nop\"",
    abi: "foo:1", effects: @["unknown"])])
let output = escape(unit,
  Selection(target: "aarch64-freestanding-none", level: "hardware"))
doAssert output.module.funcs[0].blocks[0].instrs[0].kind == Opcode.Native
doAssert output.module.native.len == 1
doAssert output.code.len == 0
echo "native escape parity: ok"
