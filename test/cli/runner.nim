import std/[os, strutils]
import ../../src/cli/runner

let root = getTempDir() / "foo-cli-runner-test"
if dirExists(root): removeDir(root)
createDir(root)
let file = root / "main.iv"
writeFile(file, "-- comment\nstart(){ give nothing. }\n")
doAssert check(file, root)
let formatted = fmt(file)
doAssert formatted.contains("-- comment")
doAssert test(root).len == 0
removeDir(root)
echo "cli runner parity: ok"
