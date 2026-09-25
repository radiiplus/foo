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
doAssert sequenceCode.contains("foo_transfer(items, p0.data")
doAssert sequenceCode.contains("foo_hashmap_put")

let http = Extern(name: "client", symbol: "client", abi: "runtime.http",
  params: @[], ret: `Type`(kind: TypeKind.Fallible,
    elem: `Type`(kind: TypeKind.Ptr)))
let httpRuntime = runtime(@[http], printType, printName)
when defined(windows):
  doAssert httpRuntime.libraries == @["winhttp", "ws2_32"]
  doAssert httpRuntime.code.contains("WinHttpOpen")
else:
  doAssert httpRuntime.libraries == @["curl"]
doAssert not httpRuntime.code.contains("openssl/")
doAssert httpRuntime.code.contains("CURLOPT_CAINFO")
let windowsHttp = runtime(@[http], printType, printName, "windows-x64")
doAssert windowsHttp.libraries == @["winhttp", "ws2_32"]
doAssert windowsHttp.code.contains("WinHttpOpen")
echo "C runtime parity: ok"
