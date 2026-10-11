import std/tables
import ../../../src/backend/llvm/abi
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
callback.abi = "stdcall"
doAssert second != indirectName(callback)
echo "LLVM callback identities distinguish layout and terminate on recursive types"
