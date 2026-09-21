import std/tables
import ../../src/ir/node
import ../../src/ir/kind

let intType = `Type`(kind: TypeKind.Int, width: 64)
doAssert label(intType) == "integer 64"
doAssert label(`Type`(kind: TypeKind.Ptr, elem: intType)) == "pointer to integer 64"
doAssert bytes("\"A\\n\\x21\"") == @[65'u8, 10'u8, 33'u8]
doAssert quoted(@[65'u8, 0'u8, 255'u8]) == "\"A\\x00\\xff\""
let module = Module(name: "sample", funcs: @[], externs: @[])
doAssert module.name == "sample"
echo "ir node parity: ok"
