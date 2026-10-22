import std/[os, strutils, tables]
import ../../../src/backend/qbe/[abi, emitter]
import ../../../src/ir/[kind, node]

let i32 = `Type`(kind: Shape.Int, width: 32)
let input = Value(kind: Flavor.Reg, name: "input", `type`: i32)
let output = Value(kind: Flavor.Reg, name: "output", `type`: i32)
let callbackType = `Type`(kind: Shape.Function, abi: "system",
  params: @[i32], ret: i32)
let callback = Value(kind: Flavor.Reg, name: "callback", `type`: callbackType)
let foreign = Function(name: "qbe_call_system", public: true, abi: "c",
  params: @[input], ret: i32, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, `func`: "foreign_plus",
      args: @[input], dest: output)],
    term: Instruction(kind: Opcode.Return, value: output))])
let indirect = Function(name: "qbe_call_callback", public: true, abi: "c",
  params: @[callback, input], ret: i32,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, callee: callback,
      args: @[input], dest: output)],
    term: Instruction(kind: Opcode.Return, value: output))])
let exported = Function(name: "qbe_export_system", public: true,
  abi: "system", params: @[input], ret: i32,
  blocks: @[Block(label: "entry", term:
    Instruction(kind: Opcode.Return, value: input))])
let module = Module(funcs: @[foreign, indirect, exported], externs: @[
  Extern(name: "foreign_plus", symbol: "qbe_foreign_plus",
    abi: "system", params: @[i32], ret: i32)])
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
let il = emit(module, target = "linux-x64")
let shims = bridgeSource(module, "linux-x64")
doAssert "foo_qbe_bridge_foreign_plus" in il
doAssert "foo_qbe_callback_0" in il
doAssert "foo_qbe_internal_qbe_export_system" in il
doAssert "qbe_foreign_plus" in shims
doAssert "foo_qbe_abi_type_" in shims
if getEnv("FOO_QBE_ABI_OUTPUT").len > 0:
  writeFile(getEnv("FOO_QBE_ABI_OUTPUT"), il)
if getEnv("FOO_QBE_ABI_C_OUTPUT").len > 0:
  writeFile(getEnv("FOO_QBE_ABI_C_OUTPUT"), shims)
try:
  discard bridgeSource(Module(externs: @[
    Extern(name: "foreign_plus", symbol: "qbe_foreign_plus",
      abi: "vectorcall", params: @[i32], ret: i32)]), "linux-x64")
  doAssert false, "Windows calling convention must be target-gated"
except ValueError as error:
  doAssert "windows-x64" in error.msg

echo "QBE ABI adapters probe: ok"
