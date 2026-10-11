## Execute both directions of the pointer ABI, including an aggregate callback.
import std/[os, osproc, strutils, tables]
import ../../../src/backend/llvm/driver
import ../../../src/build/options
import ../../../src/ir/[node, kind]

when defined(windows):
  let root = absolutePath(".artifacts/llvm-ffi")
  createDir(root)
  let integer = node.Type(kind: TypeKind.Int, width: 32)
  let pair = node.Type(kind: TypeKind.Struct, name: "Pair", fields: {"left": integer, "right": integer}.toOrderedTable)
  let callback = node.Type(kind: TypeKind.Function, params: @[pair], ret: pair)
  proc reg(name: string; t: node.Type): Value = Value(kind: ValueKind.Reg, name: name, type: t)
  proc number(n: int): Value = Value(kind: ValueKind.Const, name: $n, bits: $n, type: integer)
  let input = reg("input", pair)
  let made = reg("made", pair)
  let answer = reg("answer", integer)
  let module = Module(funcs: @[
    Function(name: "echoPair", params: @[input], ret: pair, blocks: @[
      node.Block(label: "entry", term: Instruction(kind: InstrKind.Return, value: input))]),
    Function(name: "main", ret: integer, blocks: @[
      node.Block(label: "entry", instrs: @[
        Instruction(kind: InstrKind.Construct, dest: made, args: @[number(19), number(23)]),
        Instruction(kind: InstrKind.Call, `func`: "foreignInvoke", dest: answer, args: @[
          Value(kind: ValueKind.Global, name: "echoPair", type: callback), made])],
        term: Instruction(kind: InstrKind.Return, value: answer))])],
    externs: @[Extern(name: "foreignInvoke", symbol: "foreign_invoke", abi: "c", params: @[callback, pair], ret: integer)])
  let source = root / "foreign.c"
  writeFile(source, """
#include <stdint.h>
typedef struct { int32_t left, right; } Pair;
int32_t foreign_invoke(Pair (*callback)(Pair), Pair value) {
  Pair returned = callback(value);
  return returned.left + returned.right;
}
""")
  for mode in ["dev", "release"]:
    let directory = root / mode
    let built = build(module, mode, directory, Native(name: "ffi", compile: true, sources: @[source]))
    doAssert built.success, built.error
    let emitted = readFile(directory / "main.ll")
    doAssert emitted.contains("define void @foo_llvm_gate_")
    doAssert emitted.contains("@foo_llvm_callback_")
    doAssert emitted.contains("call void @llvm_")
    doAssert fileExists(directory / "verified.ll")
    doAssert execCmdEx(quoteShell(built.artifact)).exitCode == 42
  echo "LLVM FFI and aggregate callback ABI execute correctly at O0/O2"
else:
  echo "LLVM runtime ABI execution is qualified only on Windows x64"


