import std/strutils
import ../../src/backend/native/escape
import ../../src/backend/substrate
import ../../src/ir/node
import ../../src/ir/kind

let nativeContract = NativeContract(id: "hello", stage: "@c", code: "return 1;", abi: "c", effects: @[])
let module = Module(name: "demo", funcs: @[], externs: @[], native: @[nativeContract])
let result = escape(module, Selection(target: "linux-x64", level: "system"))
doAssert result.code.contains("return 1;")
doAssert result.module.native.len == 0

let nested = Instruction(kind: InstrKind.Native, symbol: "nested",
  dest: Value(`type`: `Type`(kind: TypeKind.Void)), args: @[])
let fallback = Block(label: "fallback", instrs: @[nested])
let entry = Block(label: "entry",
  instrs: @[Instruction(kind: InstrKind.Load, fallback: fallback)])
let nestedModule = Module(name: "nested", funcs: @[
  Function(name: "start", blocks: @[entry])], native: @[
  NativeContract(id: "nested", stage: "@c",
    code: "#include <stddef.h>\nreturn;", abi: "c", effects: @[])])
let nestedResult = escape(nestedModule,
  Selection(target: "linux-x64", level: "system"))
doAssert nestedResult.module.funcs[0].blocks[0].instrs[0].fallback.instrs[0].kind == InstrKind.Call
doAssert nestedResult.module.externs.len == 1
doAssert nestedResult.code.count("#include <stddef.h>") == 1
doAssert not nestedResult.code.contains("// #include")

let inlineInstruction = Instruction(kind: InstrKind.Native, symbol: "bootasm")
let inlineModule = Module(name: "inline", funcs: @[
  Function(name: "boot", attributes: @["start", "naked"],
    ret: `Type`(kind: TypeKind.Void), blocks: @[
      Block(label: "entry", instrs: @[inlineInstruction],
        term: Instruction(kind: InstrKind.Return))])], native: @[
  NativeContract(id: "bootasm", stage: "@asm", code: "\"nop\"",
    abi: "foo:1", effects: @["unknown"])])
let inlineResult = escape(inlineModule,
  Selection(target: "aarch64-freestanding-none", level: "hardware"))
doAssert inlineResult.module.funcs[0].blocks[0].instrs[0].kind == InstrKind.Native
doAssert inlineResult.module.native.len == 1
doAssert inlineResult.code.len == 0
echo "native escape parity: ok"
