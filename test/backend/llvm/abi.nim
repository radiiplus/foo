import std/[tables, strutils]
import ../../../src/backend/llvm/abi
import ../../../src/backend/llvm/runtime
import ../../../src/ir/[node, kind]

let integer = node.Type(kind: TypeKind.Int, width: 32)
let record = node.Type(kind: TypeKind.Struct)
record.fields["next"] = node.Type(kind: TypeKind.Ptr, elem: record)
let callback = node.Type(kind: TypeKind.Function, params: @[record], ret: integer)
let first = indirectName(callback)
doAssert first == indirectName(callback)
record.attributes = @["packed"]
doAssert first != indirectName(callback)
record.attributes = @[]
doAssert first == indirectName(callback)
record.fieldAttrs["next"] = @["align(16)"]
doAssert first != indirectName(callback)
let choice = node.Type(kind: TypeKind.TaggedUnion)
choice.variants["one"] = integer
callback.params = @[choice]
let second = indirectName(callback)
choice.variants["two"] = integer
doAssert second != indirectName(callback)

# Host-specific conventions must not silently become the Linux C convention,
# including a callback nested in a record rather than a top-level parameter.
let foreignCallback = node.Type(kind: TypeKind.Function, abi: "stdcall", ret: integer)
let context = node.Type(kind: TypeKind.Struct)
context.fields["callback"] = foreignCallback
var unsupported = ""
try:
  discard newSupport().code(Module(externs: @[Extern(name: "handoff", abi: "c",
    params: @[context], ret: integer)]), "x86_64-pc-linux-gnu")
except ValueError as error: unsupported = error.msg
doAssert unsupported.contains("Linux callback convention"), unsupported
callback.abi = "stdcall"
doAssert second != indirectName(callback)
echo "LLVM callback identities distinguish layout and terminate on recursive types"
