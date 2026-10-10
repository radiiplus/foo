import std/os
import ../../src/cli/main

doAssert main(@[]) == 2
doAssert main(@["version"]) == 0
doAssert main(@["unknown"]) == 2

let empty = getTempDir() / "foo-empty-test-project"
if dirExists(empty): removeDir(empty)
createDir(empty / "src")
createDir(empty / "test")
writeFile(empty / "project.json", """{"source":"src"}""")
writeFile(empty / "src" / "main.iv", "display \"ready\".\n")
doAssert main(@["test", empty, "--backend", "c"]) == 1
doAssert main(@["check", empty / "src" / "main.iv", "--compact"]) == 0
removeDir(empty)
echo "cli main parity: ok"
