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
echo "Zig driver parity: ok"
