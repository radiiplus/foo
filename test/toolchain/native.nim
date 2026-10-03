import std/[os, sequtils, strutils]
import ../../src/toolchain/native

doAssert prepare(@[], @[], "cc", "").links.len == 0
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
