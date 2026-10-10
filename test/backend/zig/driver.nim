import std/strutils
import std/os
import ../../../src/backend/zig/driver
import ../../../src/ir/[kind, node]
import ../../../src/build/options

let module = Module(name: "demo", funcs: @[], externs: @[])
let output = ".artifacts" / ("test-zig-driver-" & getEnv("FOOTESTID", "local"))
let result = build(module, "dev", output, options = Native(name: "demo"))
doAssert result.success
when defined(windows): doAssert result.artifact.endsWith("demo.exe")
else: doAssert result.artifact.endsWith("demo")
doAssert fileExists(output / "main.zig")
doAssert readFile(output / "library.zig").contains("const instrumented = false;")
doAssert readFile(output / "service.zig").contains("No native services")

let ioOutput = output & "-io"
if dirExists(ioOutput): removeDir(ioOutput)
let ioModule = Module(name: "io", funcs: @[], externs: @[
  Extern(name: "output", abi: "runtime.io")])
let ioResult = build(ioModule, "dev", ioOutput, options = Native(name: "io"))
doAssert ioResult.success
doAssert fileExists(ioOutput / "service.h")
doAssert fileExists(ioOutput / "service.c")
let providers = readFile(ioOutput / "library.zig")
doAssert providers.contains("inline for (.{")
for name in ["fs", "io", "net", "process", "resource", "thread", "time", "text"]:
  doAssert providers.contains("\"" & name & "\"")

let unusedOutput = output & "-unused"
if dirExists(unusedOutput): removeDir(unusedOutput)
let unusedModule = Module(name: "unused", funcs: @[
  Function(name: "main", ret: `Type`(kind: TypeKind.Void),
    blocks: @[Block(label: "entry", term: Instruction(kind: InstrKind.Return))])],
  externs: @[Extern(name: "open", abi: "runtime.fs")])
let unusedResult = build(unusedModule, "dev", unusedOutput,
  options = Native(name: "unused"))
doAssert unusedResult.success
doAssert readFile(unusedOutput / "service.zig").contains("No native services")
doAssert not fileExists(unusedOutput / "service.c")
let docsOutput = output & "-docs"
let documented = build(module, "dev", docsOutput,
  options = Native(name: "docs", docs: true))
doAssert documented.success
doAssert fileExists(docsOutput / "docs" / "api.json")
echo "Zig driver parity: ok"
