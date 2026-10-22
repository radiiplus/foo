import std/[os, osproc, strutils, tables]
import ../../../../src/backend/qbe/[abi, emitter]
import ../../../../src/ir/[kind, node]

let i32 = `Type`(kind: Shape.Int, width: 32)
let input = Value(kind: Flavor.Reg, name: "input", `type`: i32)
let output = Value(kind: Flavor.Reg, name: "output", `type`: i32)
let conventions = @["stdcall", "fastcall", "vectorcall", "thiscall"]
var module = Module()
for convention in conventions:
  let name = "foreign_" & convention
  module.externs.add(Extern(name: name, symbol: "qbe_" & name,
    abi: convention, params: @[i32], ret: i32))
  module.funcs.add(Function(name: "qbe_call_" & convention, public: true,
    abi: "c", params: @[input], ret: i32,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Call, `func`: name, args: @[input],
        dest: output)],
      term: Instruction(kind: Opcode.Return, value: output))]))

let callbackType = `Type`(kind: Shape.Function, abi: "vectorcall",
  params: @[i32], ret: i32)
let callback = Value(kind: Flavor.Reg, name: "callback", `type`: callbackType)
module.funcs.add(Function(name: "qbe_call_vector_callback", public: true,
  abi: "c", params: @[callback, input], ret: i32,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, callee: callback,
      args: @[input], dest: output)],
    term: Instruction(kind: Opcode.Return, value: output))]))
module.funcs.add(Function(name: "qbe_export_vectorcall", public: true,
  abi: "vectorcall", params: @[input], ret: i32,
  blocks: @[Block(label: "entry", term:
    Instruction(kind: Opcode.Return, value: input))]))

let pair = `Type`(kind: Shape.Struct,
  fields: initOrderedTable[string, `Type`]())
pair.fields["first"] = i32
pair.fields["second"] = i32
let wide = `Type`(kind: Shape.Uint, width: 128)
for (suffix, valueType) in [("pair", pair), ("wide", wide)]:
  let incoming = Value(kind: Flavor.Reg, name: "incoming_" & suffix,
    `type`: valueType)
  let outgoing = Value(kind: Flavor.Reg, name: "outgoing_" & suffix,
    `type`: valueType)
  module.externs.add(Extern(name: "foreign_" & suffix,
    symbol: "qbe_foreign_" & suffix, abi: "system",
    params: @[valueType], ret: valueType))
  module.funcs.add(Function(name: "qbe_call_" & suffix, public: true,
    abi: "c", params: @[incoming], ret: valueType,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Call, `func`: "foreign_" & suffix,
        args: @[incoming], dest: outgoing)],
      term: Instruction(kind: Opcode.Return, value: outgoing))]))
  module.funcs.add(Function(name: "qbe_export_" & suffix, public: true,
    abi: "system", params: @[incoming], ret: valueType,
    blocks: @[Block(label: "entry", term:
      Instruction(kind: Opcode.Return, value: incoming))]))

let il = emit(module, target = "windows-x64")
let shims = bridgeSource(module, "windows-x64")
doAssert "foo_qbe_bridge_foreign_vectorcall" in il
doAssert "foo_qbe_callback_0" in il
doAssert "__vectorcall" in shims
doAssert "foo_qbe_abi_type_" in shims
try:
  discard bridgeSource(Module(externs: @[
    Extern(name: "foreign_vector_pair", symbol: "qbe_foreign_vector_pair",
      abi: "vectorcall", params: @[pair], ret: pair)]), "windows-x64")
  doAssert false, "TinyCC must reject vectorcall aggregates"
except ValueError as error:
  doAssert "vectorcall aggregate" in error.msg
if getEnv("FOO_QBE_WIN_ABI_OUTPUT").len > 0:
  writeFile(getEnv("FOO_QBE_WIN_ABI_OUTPUT"), il)
if getEnv("FOO_QBE_WIN_ABI_C_OUTPUT").len > 0:
  writeFile(getEnv("FOO_QBE_WIN_ABI_C_OUTPUT"), shims)

if getEnv("FOO_QBE").len > 0 and getEnv("FOO_QBE_TCC").len > 0:
  let directory = absolutePath(".artifacts/qbe-abi-windows")
  createDir(directory)
  let source = directory / "abi.ssa"
  let assembly = directory / "abi.s"
  let bridge = directory / "bridge.c"
  let executable = directory / "abi.exe"
  writeFile(source, il)
  writeFile(bridge, shims)
  let generated = execCmdEx(quoteShell(getEnv("FOO_QBE")) & " -t amd64_win -o " &
    quoteShell(assembly) & " " & quoteShell(source))
  doAssert generated.exitCode == 0, generated.output
  writeFile(assembly, readFile(assembly).replace("\tendbr64", "\t.byte 0xf3,0x0f,0x1e,0xfa").
    replace("\tcallq ", "\tcall "))
  let linked = execCmdEx(quoteShell(getEnv("FOO_QBE_TCC")) & " " &
    quoteShell(assembly) & " " & quoteShell(bridge) & " " &
    quoteShell("test/backend/qbe/abi/windows.c") & " " &
    quoteShell("tools/tcc/foo-winapi.def") & " -o " & quoteShell(executable))
  doAssert linked.exitCode == 0, linked.output
  let executed = execCmdEx(quoteShell(executable))
  doAssert executed.exitCode == 0, executed.output

echo "QBE Windows ABI adapters probe: ok"
