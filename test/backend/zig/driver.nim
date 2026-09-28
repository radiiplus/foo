import std/strutils
import std/os
import ../../../src/backend/zig/driver
import ../../../src/ir/node
import ../../../src/build/options

let module = Module(name: "demo", funcs: @[], externs: @[])
let output = ".artifacts" / ("test-zig-driver-" & getEnv("FOOTESTID", "local"))
let result = build(module, "dev", output, options = Native(name: "demo"))
doAssert result.success
when defined(windows): doAssert result.artifact.endsWith("demo.exe")
else: doAssert result.artifact.endsWith("demo")
doAssert fileExists(output / "main.zig")
doAssert readFile(output / "library.zig").contains("const instrumented = false;")

let ioOutput = output & "-io"
if dirExists(ioOutput): removeDir(ioOutput)
let ioModule = Module(name: "io", funcs: @[], externs: @[
  Extern(name: "output", abi: "runtime.io")])
let ioResult = build(ioModule, "dev", ioOutput, options = Native(name: "io"))
doAssert ioResult.success
doAssert fileExists(ioOutput / "service.h")
doAssert fileExists(ioOutput / "service.c")
doAssert readFile(ioOutput / "library.zig").contains(
  ".{ \"fs\", \"io\", \"net\", \"process\", \"thread\", \"time\", \"text\" }")
echo "Zig driver parity: ok"
