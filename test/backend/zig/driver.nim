import std/strutils
import std/os
import ../../../src/backend/zig/driver
import ../../../src/ir/node
import ../../../src/build/options

let module = Module(name: "demo", funcs: @[], externs: @[])
let result = build(module, "dev", ".artifacts/test-zig-driver", options = Native(name: "demo"))
doAssert result.success
when defined(windows): doAssert result.artifact.endsWith("demo.exe")
else: doAssert result.artifact.endsWith("demo")
doAssert fileExists(".artifacts/test-zig-driver/main.zig")
echo "Zig driver parity: ok"
