import std/strutils
import ../../src/backend/c/runtime
import ../../src/ir/node
import ../../src/ir/kind

proc printType(value: `Type`): string =
  if value.kind == TypeKind.Void: "void" else: "uint64_t"
proc printName(value: string): string = value

doAssert runtime(@[], printType, printName).code.contains("foo_shutdown")
let extern = Extern(name: "output", symbol: "write", abi: "runtime.io", params: @[], ret: `Type`(kind: TypeKind.Void))
let generated = runtime(@[extern], printType, printName)
doAssert generated.code.contains("FOO_SERVICE")
doAssert generated.code.contains("foo_io_write")

let sequence = Extern(name: "append", symbol: "append", abi: "runtime.sequence",
  params: @[`Type`(kind: TypeKind.Slice, elem: `Type`(kind: TypeKind.Uint, width: 64)),
    `Type`(kind: TypeKind.Uint, width: 64)],
  ret: `Type`(kind: TypeKind.Fallible,
    elem: `Type`(kind: TypeKind.Slice, elem: `Type`(kind: TypeKind.Uint, width: 64))))
let sequenceCode = runtime(@[sequence], printType, printName).code
doAssert sequenceCode.contains("foo_owned")
doAssert sequenceCode.contains("items[p0.len] = p1")
echo "C runtime parity: ok"
