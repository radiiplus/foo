import ../../src/backend/native/service
import ../../src/ir/node

let module = Module(name: "demo", funcs: @[], externs: @[Extern(name: "print", abi: "runtime.io")])
doAssert hosted(module)
doAssert libraries("windows") == @["ws2_32"]
doAssert libraries("macos") == @[]
doAssert libraries("linux") == @["pthread"]
echo "service parity: ok"
