import std/[os, strutils]
import ../../src/build/query

let root = getTempDir() / "foo-query-test"
createDir(root)
let source = root / "main.iv"
writeFile(source, "start() {}")
let queries = newQueries()
doAssert queries.input(source) == "start() {}"
let value = queries.batch(proc(): string = queries.input(source))
doAssert value == "start() {}"
let computed = queries.get("program", proc(): string = queries.input(source) & " parsed")
doAssert computed.endsWith("parsed")
doAssert queries.hits == 0
doAssert queries.misses == 1
doAssert queries.get("program", proc(): string = "wrong") == computed
doAssert queries.hits == 1
writeFile(source, "start() { give. }")
doAssert not queries.valid(queries.dependencies("program"))
doAssert queries.get("program", proc(): string = queries.input(source)) == "start() { give. }"
doAssert queries.misses == 2
doAssert inputs(root).len == 1
doAssert fingerprint(root).len == 64
removeFile(source); removeDir(root)
echo "build query parity: ok"
