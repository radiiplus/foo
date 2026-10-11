## Execute both directions of the pointer ABI, including an aggregate callback.
import std/[os, osproc, strutils, tables]
import ../../../src/backend/llvm/driver
import ../../../src/build/options
import ../../../src/ir/[node, kind]

when defined(windows) or defined(linux):
  let root = absolutePath(".artifacts/llvm-ffi")
  createDir(root)
  let integer = node.Type(kind: TypeKind.Int, width: 32)
  let unit = node.Type(kind: TypeKind.Void)
  let pair = node.Type(kind: TypeKind.Struct, name: "Pair", fields: {"left": integer, "right": integer}.toOrderedTable)
  let callback = node.Type(kind: TypeKind.Function, params: @[pair], ret: pair)
  proc reg(name: string; t: node.Type): Value = Value(kind: ValueKind.Reg, name: name, type: t)
  proc number(n: int): Value = Value(kind: ValueKind.Const, name: $n, bits: $n, type: integer)
  let input = reg("input", pair)
  let made = reg("made", pair)
  let answer = reg("answer", integer)
  let nativeAnswer = reg("nativeAnswer", integer)
  let module = Module(funcs: @[
    Function(name: "echoPair", public: true, abi: (if defined(windows): "stdcall" else: "c"), params: @[input], ret: pair, blocks: @[
      node.Block(label: "entry", term: Instruction(kind: InstrKind.Return, value: input))]),
    Function(name: "main", ret: integer, blocks: @[
      node.Block(label: "entry", instrs: @[
        Instruction(kind: InstrKind.Construct, dest: made, args: @[number(19), number(23)]),
        Instruction(kind: InstrKind.Call, `func`: "foreignInvoke", dest: answer, args: @[
          Value(kind: ValueKind.Global, name: "echoPair", type: callback), made]),
        Instruction(kind: InstrKind.Call, `func`: "foreignInvoke", dest: nativeAnswer, args: @[
          Value(kind: ValueKind.Global, name: "foreignIdentity", type: callback), made]),
        Instruction(kind: InstrKind.Call, `func`: "verifyAnswer", args: @[answer]),
        Instruction(kind: InstrKind.Call, `func`: "verifyAnswer", args: @[nativeAnswer])],
        term: Instruction(kind: InstrKind.Return, value: nativeAnswer))])],
    externs: @[Extern(name: "foreignInvoke", symbol: "foreign_invoke", abi: "c", params: @[callback, pair], ret: integer),
      Extern(name: "foreignIdentity", symbol: "foreign_identity", abi: "c", params: @[pair], ret: pair),
      Extern(name: "verifyAnswer", symbol: "foreign_verify", abi: "c", params: @[integer], ret: unit)])
  let source = root / "foreign.c"
  writeFile(source, """
#include <stdint.h>
#include <assert.h>
typedef struct { int32_t left, right; } Pair;
Pair foreign_identity(Pair value) { return value; }
void foreign_verify(int32_t value) { assert(value == 42); }
#ifndef _WIN32
#define __stdcall
#endif
Pair __stdcall echoPair(Pair value);
int32_t foreign_invoke(Pair (*callback)(Pair), Pair value) {
  Pair returned = callback(value);
  assert(returned.left == 19 && returned.right == 23);
  Pair exported = echoPair(value);
  assert(exported.left == 19 && exported.right == 23);
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
    doAssert execCmdEx(quoteShell(built.artifact)).exitCode == 0
    let exports = execCmdEx((if defined(windows): "llvm-readobj --coff-exports " else: "nm -g ") & quoteShell(built.artifact))
    doAssert exports.exitCode == 0 and exports.output.contains((if defined(windows): "Name: echoPair" else: " T echoPair")), exports.output
  echo "LLVM FFI and aggregate callback ABI execute correctly at O0/O2"
else:
  echo "LLVM runtime ABI execution is qualified only on Windows/Linux x64"


