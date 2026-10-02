import std/os
import ../../src/backend/native/icon

let root = getTempDir() / "foo-backend-icon-test"
if dirExists(root): removeDir(root)
createDir(root / "assets")
writeFile(root / "assets" / "app.ico", "icon-data")

let resource = script(root / "assets" / "app.ico", root / "build",
  "x86_64-windows-msvc", "exe")
doAssert fileExists(resource)
doAssert readFile(resource) == "1 ICON \"icon.ico\"\n"
doAssert readFile(root / "build" / "icon.ico") == "icon-data"
doAssert script(root / "assets" / "app.ico", root / "linux",
  "x86_64-linux-gnu", "exe").len == 0
doAssert script(root / "assets" / "app.ico", root / "library",
  "x86_64-windows-msvc", "shared").len == 0

removeDir(root)
echo "native icon parity: ok"
