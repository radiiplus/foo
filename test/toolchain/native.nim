import std/[os, sequtils, strutils]
import ../../src/toolchain/native

doAssert prepare(@[], @[], "cc", "").links.len == 0
when defined(windows) and defined(amd64):
  let bundled = prepare(@["sodium"], @[], "clang", "")
  doAssert bundled.headers.len == 1
  doAssert bundled.links.len == 1
  doAssert bundled.defines == @["SODIUM_STATIC=1"]
  doAssert fileExists(bundled.headers[0] / "sodium.h")
  doAssert fileExists(bundled.links[0].path)
when defined(linux):
  if getEnv("FOO_NATIVE_PROBE") == "1":
    let supply = prepare(@["sodium", "z", "curl"], @[], "missing-compiler", "")
    doAssert supply.links.len == 3
    doAssert supply.headers.len == 3
    doAssert supply.runtime.len == 1
    doAssert supply.links.allIt(fileExists(it.path))
    doAssert supply.links.anyIt(it.name == "sodium" and it.path.endsWith("libsodium.a"))
    doAssert supply.links.anyIt(it.name == "z" and it.path.endsWith("libz.a"))
    doAssert fileExists(supply.runtime[0])
echo "native dependency parity: ok"
