import std/tables
import ../../src/ir/node
import ../../src/ir/kind

let representation = `Type`(kind: Shape.Int, width: 64)
doAssert label(representation) == "integer"
doAssert label(`Type`(kind: Shape.Ptr, elem: representation)) == "pointer to integer"
doAssert bytes("\"A\\n\\x21\"") == @[65'u8, 10'u8, 33'u8]
doAssert quoted(@[65'u8, 0'u8, 255'u8]) == "\"A\\x00\\xff\""
let module = Module(name: "sample", funcs: @[], externs: @[])
doAssert module.name == "sample"
doAssert operations[ord(Opcode.Alloc)] == "slot"
doAssert operations[ord(Opcode.Convert)] == "convert"
doAssert operations[ord(Opcode.Bit)] == "bit"
doAssert ord(Shape.Trace) == 21
doAssert ord(Flavor.Global) == 2
echo "ir node parity: ok"
