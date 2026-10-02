import std/[os, strutils]
import ../../../src/backend/c/driver
import ../../../src/ir/node
import ../../../src/build/options

doAssert dependencies("main.o: main.c helper.h") ==
  @[absolutePath("main.c"), absolutePath("helper.h")]
doAssert deadStripFlag("x86_64-windows-msvc", "clang").contains("/OPT:REF")
doAssert deadStripFlag("x86_64-windows-gnu", "clang") ==
  "-Wl,--gc-sections"
doAssert deadStripFlag("x86_64-windows-gnu", "gcc") ==
  "-Wl,--gc-sections"
when defined(windows):
  doAssert deadStripFlag("", "gcc") == "-Wl,--gc-sections"
doAssert deadStripFlag("aarch64-macos", "clang") == "-Wl,-dead_strip"
doAssert deadStripFlag("x86_64-linux-gnu", "cc") ==
  "-Wl,--gc-sections"
let module = Module(name: "demo", funcs: @[], externs: @[])
let output = ".artifacts" / ("test-driver-" & getEnv("FOOTESTID", "local"))
let result = build(module, "dev", output, Native(name: "demo"))
doAssert result.success
when defined(windows): doAssert result.artifact.endsWith("demo.exe")
else: doAssert result.artifact.endsWith("demo")

let documented = build(module, "dev", output & "-docs",
  Native(name: "docs", docs: true))
doAssert documented.success
doAssert fileExists(output & "-docs" / "docs" / "api.json")
echo "C driver parity: ok"
