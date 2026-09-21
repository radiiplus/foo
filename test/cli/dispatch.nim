import std/[os, strutils]
import ../../src/cli/main

doAssert main(@["version"]) == 0
doAssert main(@["toolchain"]) == 0
let root = getTempDir() / "foo-cli-dispatch-test"
if dirExists(root): removeDir(root)
createDir(root)
let header = root / "foreign.h"
writeFile(header, "int increment(int value);\n")
doAssert main(@["bind", header]) == 0
removeDir(root)
echo "cli dispatch parity: ok"
