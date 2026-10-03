import std/[os, sequtils]
import ../../src/toolchain/doctor

let root = getTempDir() / "foo-doctor-test"
if dirExists(root): removeDir(root)
createDir(root / "src")
writeFile(root / "src" / "main.iv", "use crypto.\nuse compress.\nuse http.\nstart { give nothing. }")
writeFile(root / "project.json", "{\"name\":\"doctor\",\"language\":\"1\",\"version\":\"0.1.0\",\"source\":\"src\"}")
let report = doctor(root)
doAssert report.len >= 2
doAssert report.anyIt(it.name == "Backend")
doAssert report.anyIt(it.name == "Headers")
doAssert report.anyIt(it.name == "C crypto")
doAssert report.anyIt(it.name == "C compression")
when not defined(windows):
  doAssert report.anyIt(it.name == "C HTTP")
removeDir(root)
echo "toolchain doctor parity: ok"
