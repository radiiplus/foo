import std/[json, strutils]
import ../../../src/backend/llvm/effects
import ../../../src/ir/[node, kind]

let handleType = node.Type(kind: TypeKind.Ptr)
let handle = Value(kind: ValueKind.Reg, name: "stream", type: handleType)
let other = Value(kind: ValueKind.Reg, name: "other", type: handleType)
let text = Value(kind: ValueKind.Const, name: "bytes")
proc write(handle: Value, index: int): Instruction =
  Instruction(kind: InstrKind.Call, `func`: "write", args: @[handle, text],
    dest: Value(kind: ValueKind.Reg, name: "result" & $index),
    span: SourceSpan(file: "ordering.iv", start: index * 10, `end`: index * 10 + 5))
let module = Module(externs: @[Extern(name: "write", abi: "runtime.io", symbol: "write")],
  funcs: @[Function(name: "main", blocks: @[
    node.Block(label: "entry", instrs: @[
      write(handle, 1), write(handle, 2),
      Instruction(kind: InstrKind.Call, `func`: "sync"),
      write(handle, 3), write(other, 4),
      Instruction(kind: InstrKind.Trace), write(handle, 5)]),
    node.Block(label: "next", instrs: @[write(handle, 6)])])])
let report = ioReport(module)
doAssert report["enabled"].getBool() == false
doAssert report["formedBatches"].getInt() == 0
doAssert report["operations"].getInt() == 6
let candidates = report["candidates"]
doAssert candidates.len == 5
doAssert candidates[0]["count"].getInt() == 2
doAssert candidates[0]["reason"].getStr().contains("flushes")
doAssert candidates[0]["boundary"].getStr().contains("ordering barrier")
doAssert candidates[1]["boundary"].getStr() == "different or unproven handle"
doAssert candidates[2]["boundary"].getStr().contains("Trace")
doAssert candidates[3]["boundary"].getStr() == "basic block boundary"
var expected = 1
for candidate in candidates:
  doAssert not candidate["formed"].getBool()
  for slot in candidate["slots"]:
    doAssert slot["result"].getStr() == "result" & $expected
    doAssert slot["file"].getStr() == "ordering.iv"
    doAssert slot["start"].getInt() == expected * 10
    doAssert slot["end"].getInt() == expected * 10 + 5
    inc expected
echo "LLVM I/O diagnostics preserve barriers, source operations and error slots"
