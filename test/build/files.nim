import std/[os, sequtils, strutils, unittest]
import ../../src/build/files

let root = getTempDir() / "foo-build-files-test"
if dirExists(root): removeDir(root)
createDir(root / "src" / "nested")
write(root / "src" / "main.iv", "start {}")
write(root / "src" / "nested" / "helper.iv", "function helper {}")
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
doAssert destination(root, "", @["src", "test", "benchmark"]) ==
  absolutePath(root / "output")
doAssert destination(root, "target", @["src", "test", "benchmark"]) ==
  absolutePath(root / "target")
doAssert destination(root, "dist/native", @["src"]) ==
  absolutePath(root / "dist" / "native")
for invalid in ["../outside", ".artifacts/output", "src/output", "project.json"]:
  expect ValueError:
    discard destination(root, invalid, @["src"])
createDir(root / "dist")
write(root / "dist" / "generated.iv", "generated")
doAssert "dist/generated.iv" notin glob(root, "**/*.iv", @[root / "dist"])
createDir(root / "output")
createDir(root / "release")
write(root / "output" / "generated.iv", "generated")
write(root / "release" / "generated.iv", "generated")
let discovered = discover(root, ".").mapIt(it.replace('\\', '/'))
doAssert discovered.allIt(not it.contains("/output/generated.iv"))
doAssert discovered.allIt(not it.contains("/release/generated.iv"))

let stable = root / "generated" / "out.txt"
write(stable, "same")
let before = getLastModificationTime(stable)
write(stable, "same")
doAssert getLastModificationTime(stable) == before
write(stable, "changed")
doAssert readFile(stable) == "changed"
removeDir(root)
echo "build files parity: ok"
