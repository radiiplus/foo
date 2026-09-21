import std/[os, strutils, unittest]
import ../../src/build/files

let root = getTempDir() / "foo-build-files-test"
if dirExists(root): removeDir(root)
createDir(root / "src" / "nested")
write(root / "src" / "main.iv", "start() {}")
write(root / "src" / "nested" / "helper.iv", "function helper() {}")
write(root / "src" / "skip.txt", "ignored")
createDir(root / ".artifacts")
write(root / ".artifacts" / "generated.iv", "ignored")

doAssert confined(root, "src/main.iv") == absolutePath(root / "src/main.iv")
expect ValueError:
  discard confined(root, "../outside.iv")
doAssert glob(root / "src", "**/*.iv") == @["main.iv", "nested/helper.iv"]
expect ValueError:
  discard glob(root, "../*.iv")
doAssert discover(root).len == 2

let stable = root / "generated" / "out.txt"
write(stable, "same")
let before = getLastModificationTime(stable)
write(stable, "same")
doAssert getLastModificationTime(stable) == before
write(stable, "changed")
doAssert readFile(stable) == "changed"
removeDir(root)
echo "build files parity: ok"
