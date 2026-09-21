import std/[json, os, tables]
import ../../src/build/tasks

let root = getTempDir() / "foo-build-tasks-test"
if dirExists(root): removeDir(root)
createDir(root / "assets" / "nested")
writeFile(root / "assets" / "one.txt", "hello")
writeFile(root / "assets" / "nested" / "two.txt", "world")
var definitions = {
  "version": Task(kind: "text", output: "version.iv", text: "value {{number}}", values: {"number": %*42}.toTable),
  "resources": Task(kind: "embed", output: "resources", inputs: @["assets/**/*.txt"]),
}.toTable
let generated = tasks(root, definitions)
doAssert generated.len == 2
doAssert readFile(root / ".artifacts/build/generated/version.iv") == "value 42"
let embedded = readFile(root / ".artifacts/build/generated/resources")
doAssert embedded[0 .. 4] == "FOO\0\1"
definitions["copy"] = Task(kind: "copy", output: "copy.iv", needs: @["version"], inputs: @["@version"])
let chained = tasks(root, definitions, @["copy"])
doAssert readFile(chained[0]) == "value 42"
let cycle = {"a": Task(kind: "text", output: "a", needs: @["b"]), "b": Task(kind: "text", output: "b", needs: @["a"])}.toTable
try:
  discard tasks(root, cycle)
  doAssert false
except ValueError: discard
removeDir(root)
echo "build tasks parity: ok"
