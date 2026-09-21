import std/[os, json]
import ../../src/toolchain/manager

doAssert version == "0.16.0"
doAssert pin(getTempDir()) == version
doAssert detect("unsupported").path.len == 0
doAssert directory().len > 0
let root = getTempDir() / "foo-toolchain-manager-test"
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "foo.lock", "{\"zig\":\"0.16.0\"}")
doAssert pin(root) == version
writeFile(root / "foo.lock", "{\"zig\":\"0.15.0\"}")
try:
  discard pin(root)
  doAssert false
except ValueError: discard
removeDir(root)
echo "toolchain manager parity: ok"
