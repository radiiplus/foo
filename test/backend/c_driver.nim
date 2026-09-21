import std/[os, strutils]
import ../../src/backend/c/driver
import ../../src/ir/node
import ../../src/ir/kind
import ../../src/build/options

doAssert dependencies("main.o: main.c helper.h") ==
  @[absolutePath("main.c"), absolutePath("helper.h")]
let module = Module(name: "demo", funcs: @[], externs: @[])
let result = build(module, "dev", ".artifacts/test-driver", Native(name: "demo"))
doAssert result.success
when defined(windows): doAssert result.artifact.endsWith("demo.exe")
else: doAssert result.artifact.endsWith("demo")
echo "C driver parity: ok"
