import std/[os, sequtils]
import ../../src/toolchain/doctor
import std/json
import ../../src/toolchain/zig
import ../../src/config/project as configuration

let root = getTempDir() / "foo-doctor-test"
if dirExists(root): removeDir(root)
createDir(root / "src")
writeFile(root / "src" / "main.iv", "use crypto.\nuse compress.\nuse http.\nstart { give nothing. }")
configuration.writeProject(root, %*{"name": "doctor", "version": "0.1.0",
  "source": "src"})
let report = doctor(root)
doAssert report.len >= 2
doAssert report.anyIt(it.name == "QBE toolchain")
doAssert report.anyIt(it.name == "Headers")
doAssert report.anyIt(it.name == "C crypto")
doAssert report.anyIt(it.name == "C compression")
when not defined(windows):
  doAssert report.anyIt(it.name == "C HTTP")
removeDir(root)
echo "toolchain doctor parity: ok"

block managerPolicy:
  doAssert version == "0.16.0"
  doAssert pin(getTempDir()) == version
  doAssert detect("unsupported").path.len == 0
  doAssert directory().len > 0
  doAssert size(0) == "0 B"
  doAssert size(1024) == "1.0 KiB"
  doAssert size(5 * 1024 * 1024) == "5.0 MiB"
  doAssert meter(5 * 1024 * 1024, 20 * 1024 * 1024, 1024 * 1024) ==
    "Downloaded 5.0 MiB / 20.0 MiB (25%) at 1.0 MiB/s"
  doAssert size(%*{"size": "59241884"}) == 59241884
  doAssert size(%*{"size": 59241884}) == 59241884

  for invalid in [%*{"size": ""}, %*{"size": "unknown"}, %*{"size": 0},
      %*{"size": "536870913"}]:
    try:
      discard size(invalid)
      doAssert false
    except ValueError: discard

  let root = getTempDir() / "foo-toolchain-manager-test"
  if dirExists(root): removeDir(root)
  createDir(root)
  writeFile(root / "foo.ivl", "{\"format\":\"foo.ivl\",\"version\":1}")
  doAssert pin(root) == version
  writeFile(root / "foo.ivl", "{\"zig\":\"0.16.0\"}")
  doAssert pin(root) == version
  writeFile(root / "foo.ivl", "{\"zig\":\"0.15.0\"}")
  try:
    discard pin(root)
    doAssert false
  except ValueError: discard
  removeDir(root)
echo "toolchain manager parity: ok"
