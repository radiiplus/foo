import ../../src/runtime/provider/service
import ../../src/ir/node
import ../../src/build/options

let unit = Module(name: "demo", funcs: @[], externs: @[Extern(name: "print", abi: "runtime.io")])
let module = Module(name: "demo", funcs: @[], externs: @[Extern(name: "open", abi: "runtime.fs")])
doAssert hosted(unit)
doAssert not hosted(unit, includeIo = false)
doAssert hosted(module)
doAssert not hosted(Module(name: "task", externs: @[
  Extern(name: "run", abi: "runtime")]), includeTask = false)
doAssert resources(unit) == @[
  "-DFOO_SERVICE_SELECTIVE", "-DFOO_SERVICE_FS"]
doAssert resources(Module(name: "mixed", externs: @[
  Extern(name: "connect", abi: "runtime.net"),
  Extern(name: "pool", abi: "runtime")])) == @[
    "-DFOO_SERVICE_SELECTIVE", "-DFOO_SERVICE_NET",
    "-DFOO_SERVICE_THREAD", "-DFOO_SERVICE_TASK"]
doAssert libraries("windows") == @["ws2_32", "dnsapi", "iphlpapi"]
doAssert libraries("macos") == @["resolv"]
doAssert libraries("linux") == @["pthread", "resolv", "dl"]
doAssert selective(Native(kind: "exe"), false)
doAssert not selective(Native(kind: "static"), false)
doAssert not selective(Native(kind: "exe", sources: @["native.c"]), false)
doAssert not selective(Native(kind: "exe"), true)
echo "service parity: ok"
