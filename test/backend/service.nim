import ../../src/backend/native/service
import ../../src/ir/node

let ioModule = Module(name: "demo", funcs: @[], externs: @[Extern(name: "print", abi: "runtime.io")])
let fileModule = Module(name: "demo", funcs: @[], externs: @[Extern(name: "open", abi: "runtime.fs")])
doAssert hosted(ioModule)
doAssert not hosted(ioModule, includeIo = false)
doAssert hosted(fileModule)
doAssert libraries("windows") == @["ws2_32"]
doAssert libraries("macos") == @[]
doAssert libraries("linux") == @["pthread"]
echo "service parity: ok"
