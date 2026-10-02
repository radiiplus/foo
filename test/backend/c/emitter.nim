import std/[sequtils, strutils]
import ../../../src/backend/c/emitter
import ../../../src/ir/node
import ../../../src/ir/kind

let function = Function(name: "main", params: @[], ret: `Type`(kind: TypeKind.Void), blocks: @[
  Block(label: "entry", instrs: @[], term: Instruction(kind: InstrKind.Return))
])
let module = Module(name: "demo", funcs: @[function], externs: @[])
let generated = emit(module)
doAssert generated.code.contains("foo_symbol_main")
doAssert generated.code.contains("#include <stdint.h>")
doAssert not generated.code.contains("#define FOO_BENCHMARK 1")
let types = newTypes()
doAssert types.get(`Type`(kind: TypeKind.Int, width: 7)) == "int8_t"
doAssert types.get(`Type`(kind: TypeKind.Uint, width: 100)) == "foo_u128"
let measured = emit(module, options = Options(benchmark: true))
doAssert measured.code.contains("#define FOO_BENCHMARK 1")
doAssert measured.code.contains("foo_benchmark_report()")

let boot = Function(name: "boot", params: @[], ret: `Type`(kind: TypeKind.Void),
  attributes: @["start", "naked"], blocks: @[
  Block(label: "entry", instrs: @[], term: Instruction(kind: InstrKind.Return))])
let bare = emit(Module(name: "bare", funcs: @[boot]), options = Options(
  target: "aarch64-freestanding-none", runtime: "none", level: "hardware"))
doAssert bare.code.contains("FOO_NAKED void _start(void)")
doAssert not bare.code.contains("#include <stdlib.h>")
doAssert not bare.code.contains("int main(")

let interrupt = Function(name: "irq", params: @[], ret: `Type`(kind: TypeKind.Void),
  attributes: @["interrupt"], blocks: @[
  Block(label: "entry", instrs: @[], term: Instruction(kind: InstrKind.Return))])
let hardware = emit(Module(name: "hardware", funcs: @[interrupt]),
  options = Options(target: "riscv64-freestanding-none", runtime: "none",
    level: "hardware"))
doAssert hardware.code.contains("FOO_INTERRUPT void irq(void)")

let accelerated = Function(name: "accelerated", params: @[],
  ret: `Type`(kind: TypeKind.Void), attributes: @["target_feature(\"sse2\")"],
  blocks: @[Block(label: "entry", instrs: @[],
    term: Instruction(kind: InstrKind.Return))])
let featured = emit(Module(name: "featured", funcs: @[accelerated]),
  options = Options(target: "x86_64-linux-gnu", cpu: "x86-64"))
doAssert featured.code.contains("FOO_TARGET(\"sse2\")")
let callbackTypes = newTypes()
let callback = callbackTypes.get(`Type`(kind: TypeKind.Function, abi: "stdcall",
  params: @[], ret: `Type`(kind: TypeKind.Void)))
doAssert callback.startsWith("foo_type_")
doAssert callbackTypes.declarations.anyIt(it.contains("FOO_STDCALL"))
echo "C emitter parity: ok"
