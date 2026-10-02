import std/[os, strutils]
import ../../src/build/project
import ../../src/build/release

let root = getTempDir() / "foo-build-release-test"
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "project.json", """{
  "name": "release-test",
  "version": "1.2.3",
  "language": "1",
  "source": "src",
  "requires": "base",
  "dependencies": {},
  "release": {
    "directory": "release",
    "license": "LICENSE",
    "sign": { "provider": "authenticode", "timestamp": "https://example.invalid" }
  }
}
""")
let deployment = newProject(root).manifest().deployment
doAssert deployment.directory == "release"
doAssert deployment.license == "LICENSE"
doAssert deployment.signing.provider == "authenticode"

writeFile(root / "app.exe", "not-a-real-executable")
let previous = getEnv("FOOSIGNER")
delEnv("FOOSIGNER")
var rejected = false
try:
  discard sign(root / "app.exe", deployment.signing, "x86_64-windows-msvc")
except ValueError as error:
  rejected = error.msg.contains("FOOSIGNER")
if previous.len > 0: putEnv("FOOSIGNER", previous)
doAssert rejected

removeDir(root)
echo "release configuration parity: ok"
