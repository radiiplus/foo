import std/strutils
import ../../src/backend/native/machine
import ../../src/backend/substrate
import ../../src/ir/node
import ../../src/ir/kind

let options = Selection(target: "linux-x64")
let bits = `Type`(kind: TypeKind.Ptr, elem: `Type`(kind: TypeKind.Uint, width: 64))
doAssert machine("set", @[bits], options).contains("|=")
doAssert machine("register:rax", @[], options).contains("movq")
var rejected = false
try: discard machine("register:x0", @[], options)
except ValueError: rejected = true
doAssert rejected
echo "machine backend parity: ok"
