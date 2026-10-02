import ../../src/backend/native/service
import ../../src/ir/node
import ../../src/build/options

let ioModule = Module(name: "demo", funcs: @[], externs: @[Extern(name: "print", abi: "runtime.io")])
let fileModule = Module(name: "demo", funcs: @[], externs: @[Extern(name: "open", abi: "runtime.fs")])
doAssert hosted(ioModule)
doAssert not hosted(ioModule, includeIo = false)
doAssert hosted(fileModule)
doAssert not hosted(Module(name: "task", externs: @[
  Extern(name: "run", abi: "runtime")]), includeTask = false)
doAssert resourceDefines(ioModule) == @[
  "-DFOO_SERVICE_SELECTIVE", "-DFOO_SERVICE_FS"]
doAssert resourceDefines(Module(name: "mixed", externs: @[
  Extern(name: "connect", abi: "runtime.net"),
  Extern(name: "pool", abi: "runtime")])) == @[
    "-DFOO_SERVICE_SELECTIVE", "-DFOO_SERVICE_NET",
    "-DFOO_SERVICE_THREAD", "-DFOO_SERVICE_TASK"]
doAssert libraries("windows") == @["ws2_32"]
doAssert libraries("macos") == @[]
doAssert libraries("linux") == @["pthread"]
doAssert selective(Native(kind: "exe"), false)
doAssert not selective(Native(kind: "static"), false)
doAssert not selective(Native(kind: "exe", sources: @["native.c"]), false)
doAssert not selective(Native(kind: "exe"), true)
echo "service parity: ok"
