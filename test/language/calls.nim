import std/[os, sequtils]
import ../../src/build/compiler
import ../../src/ir/[kind, node]

let root = getCurrentDir()
let fixture = root / "test" / "language" / "calls.iv"
let output = newCompiler(root, backend = "c").ir(fixture)

doAssert output.funcs.anyIt(it.name == "identify__overload_1")
doAssert output.funcs.anyIt(it.name == "identify__overload_2")
let variadic = output.funcs.filterIt(it.name == "total")[0]
doAssert variadic.params.len == 1
doAssert variadic.params[0].type.kind == TypeKind.Slice
doAssert variadic.params[0].type.constant

let entry = output.funcs.filterIt(it.name == "main")[0]
var packed = false
for basicBlock in entry.blocks:
  for instruction in basicBlock.instrs:
    if instruction.kind == InstrKind.Construct and
        instruction.dest.type != nil and
        instruction.dest.type.kind == TypeKind.Slice:
      packed = instruction.args.len == 4
doAssert packed

let increment = output.funcs.filterIt(it.name == "increment")[0]
var arithmetic = false
for basic in increment.blocks:
  for instruction in basic.instrs:
    if instruction.kind == InstrKind.Add:
      doAssert instruction.val.type.kind == TypeKind.Int
      doAssert instruction.val2.type.kind == TypeKind.Int
      arithmetic = true
doAssert arithmetic

echo "advanced call forms: ok"
