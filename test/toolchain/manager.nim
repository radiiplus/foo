import std/[os, json]
import ../../src/toolchain/manager

doAssert version == "0.16.0"
doAssert pin(getTempDir()) == version
doAssert detect("unsupported").path.len == 0
doAssert directory().len > 0
doAssert formatBytes(0) == "0 B"
doAssert formatBytes(1024) == "1.0 KiB"
doAssert formatBytes(5 * 1024 * 1024) == "5.0 MiB"
doAssert progressLine(5 * 1024 * 1024, 20 * 1024 * 1024, 1024 * 1024) ==
  "Downloaded 5.0 MiB / 20.0 MiB (25%) at 1.0 MiB/s"
doAssert releaseSize(%*{"size": "59241884"}) == 59241884
doAssert releaseSize(%*{"size": 59241884}) == 59241884
for invalid in [%*{"size": ""}, %*{"size": "unknown"}, %*{"size": 0},
    %*{"size": "536870913"}]:
  try:
    discard releaseSize(invalid)
    doAssert false
  except ValueError: discard
let root = getTempDir() / "foo-toolchain-manager-test"
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "foo.lock", "{\"format\":\"foo.lock\",\"version\":1}")
doAssert pin(root) == version
writeFile(root / "foo.lock", "{\"zig\":\"0.16.0\"}")
doAssert pin(root) == version
writeFile(root / "foo.lock", "{\"zig\":\"0.15.0\"}")
try:
  discard pin(root)
  doAssert false
except ValueError: discard
removeDir(root)
echo "toolchain manager parity: ok"
