import std/[strutils, tables]
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
  ret: `Type`(kind: TypeKind.Failable,
    elem: `Type`(kind: TypeKind.Slice, elem: `Type`(kind: TypeKind.Uint, width: 64))))
let sequenceCode = runtime(@[sequence], printType, printName).code
doAssert sequenceCode.contains("foo_sequence_append")
doAssert sequenceCode.contains("allocation->used < allocation->capacity")
doAssert sequenceCode.contains("branch = length < allocation->used")
doAssert sequenceCode.contains("length > allocation->used")
doAssert sequenceCode.contains("foo_sequence_find(source)")
doAssert sequenceCode.contains("foo_metric_growths")
doAssert sequenceCode.contains("slowPathHits")
doAssert sequenceCode.contains("FOO_METRICS")
doAssert sequenceCode.contains("foo_hashmap_put")

let identity = Extern(name: "identical", symbol: "identical",
  abi: "runtime.memory",
  params: @[`Type`(kind: TypeKind.Ptr), `Type`(kind: TypeKind.Ptr)],
  ret: `Type`(kind: TypeKind.Bool))
let identityCode = runtime(@[identity], printType, printName).code
doAssert identityCode.contains("foo_memory_identical(p0, p1)")
doAssert identityCode.contains("left == right")

let http = Extern(name: "client", symbol: "client", abi: "runtime.http",
  params: @[], ret: `Type`(kind: TypeKind.Failable,
    elem: `Type`(kind: TypeKind.Ptr)))
let httpRuntime = runtime(@[http], printType, printName)
when defined(windows):
  doAssert httpRuntime.libraries == @["winhttp", "ws2_32"]
  doAssert httpRuntime.code.contains("WinHttpOpen")
else:
  doAssert httpRuntime.libraries == @["curl"]
doAssert not httpRuntime.code.contains("openssl/")
doAssert httpRuntime.code.contains("CURLOPT_CAINFO")

let text = `Type`(kind: TypeKind.Slice, constant: true,
  elem: `Type`(kind: TypeKind.Uint, width: 8))
let point = `Type`(kind: TypeKind.Struct, name: "Point",
  fields: {"x": `Type`(kind: TypeKind.Int, width: 32),
    "active": `Type`(kind: TypeKind.Bool)}.toOrderedTable)
let codec = runtime(@[
  Extern(name: "encodePoint", symbol: "encode", abi: "runtime.codec",
    params: @[point], ret: `Type`(kind: TypeKind.Failable, elem: text)),
  Extern(name: "decodePoint", symbol: "decode", abi: "runtime.codec",
    params: @[text], ret: `Type`(kind: TypeKind.Failable, elem: point))],
  printType, printName).code
doAssert codec.contains("foo_quote(&writer")
doAssert codec.contains("foo_adopt(writer.data, writer.length)")
doAssert codec.contains("p0.x")
doAssert codec.contains("strtoll")
doAssert codec.contains("MissingField")
let numbers = `Type`(kind: TypeKind.Slice,
  elem: `Type`(kind: TypeKind.Int, width: 32))
let sequenceCodec = runtime(@[
  Extern(name: "encodeNumbers", symbol: "encode", abi: "runtime.codec",
    params: @[numbers], ret: `Type`(kind: TypeKind.Failable, elem: text)),
  Extern(name: "decodeNumbers", symbol: "decode", abi: "runtime.codec",
    params: @[text], ret: `Type`(kind: TypeKind.Failable, elem: numbers))],
  printType, printName).code
doAssert sequenceCodec.contains("foo_put(&writer, \"[\", 1)")
doAssert sequenceCodec.contains("ExpectedSequence")
doAssert sequenceCodec.contains("foo_sequence_owned")
let maybe = `Type`(kind: TypeKind.Optional,
  elem: `Type`(kind: TypeKind.Int, width: 32))
let optionalCodec = runtime(@[
  Extern(name: "encodeMaybe", symbol: "encode", abi: "runtime.codec",
    params: @[maybe], ret: `Type`(kind: TypeKind.Failable, elem: text)),
  Extern(name: "decodeMaybe", symbol: "decode", abi: "runtime.codec",
    params: @[text], ret: `Type`(kind: TypeKind.Failable, elem: maybe))],
  printType, printName).code
doAssert optionalCodec.contains("foo_put(&writer, \"null\", 4)")
doAssert optionalCodec.contains(".present = true")
let choice = `Type`(kind: TypeKind.TaggedUnion, name: "Selection",
  variants: {"chosen": `Type`(kind: TypeKind.Int, width: 32),
    "missing": `Type`(kind: TypeKind.Void)}.toOrderedTable)
let choiceCodec = runtime(@[
  Extern(name: "encodeChoice", symbol: "encode", abi: "runtime.codec",
    params: @[choice], ret: `Type`(kind: TypeKind.Failable, elem: text)),
  Extern(name: "decodeChoice", symbol: "decode", abi: "runtime.codec",
    params: @[text], ret: `Type`(kind: TypeKind.Failable, elem: choice))],
  printType, printName).code
doAssert choiceCodec.contains("InvalidChoice")
doAssert choiceCodec.contains("ExpectedChoicePayload")
doAssert choiceCodec.contains("UnknownVariant")
let windowsHttp = runtime(@[http], printType, printName, "windows-x64")
doAssert windowsHttp.libraries == @["winhttp", "ws2_32"]
doAssert windowsHttp.code.contains("WinHttpOpen")
echo "C runtime parity: ok"
