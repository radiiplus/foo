import std/[os, strutils, times]
import ../../src/build/query

let root = getTempDir() / "foo-query-test"
createDir(root)
let source = root / "main.iv"
writeFile(source, "start {}")
let queries = queries()
doAssert queries.input(source) == "start {}"
let value = queries.batch(proc(): string = queries.input(source))
doAssert value == "start {}"
let computed = queries.get("program", proc(): string = queries.input(source) & " parsed")
doAssert computed.endsWith("parsed")
doAssert queries.hits == 0
doAssert queries.misses == 1
doAssert queries.get("program", proc(): string = "wrong") == computed
doAssert queries.hits == 1
writeFile(source, "start { give. }")
doAssert not queries.valid(queries.dependencies("program"))
doAssert queries.get("program", proc(): string = queries.input(source)) == "start { give. }"
doAssert queries.misses == 2
doAssert inputs(root).len == 1
doAssert fingerprint(root).len == 64
let nested = queries()
let leaf = root / "leaf.iv"
writeFile(leaf, "one")
var childRuns = 0
var parentRuns = 0
proc child(): string = nested.get("child", proc(): string =
  inc childRuns
  nested.input(leaf))
proc parent(): string = nested.get("parent", proc(): string =
  inc parentRuns
  child() & "!")
doAssert parent() == "one!" and childRuns == 1 and parentRuns == 1
doAssert nested.dependencies("parent").len == 1
doAssert parent() == "one!" and parentRuns == 1
nested.forget("parent")
doAssert parent() == "one!" and childRuns == 1 and parentRuns == 2
doAssert nested.dependencies("parent").len == 1
let stamp = getLastModificationTime(leaf)
writeFile(leaf, "two")
setLastModificationTime(leaf, stamp)
doAssert parent() == "two!" and childRuns == 2 and parentRuns == 3
doAssert nested.get("grand", proc(): string = parent() & "?") == "two!?"
writeFile(leaf, "six")
doAssert nested.get("grand", proc(): string = parent() & "?") == "six!?"

let siblings = queries()
let first = root / "first.iv"
let second = root / "second.iv"
writeFile(first, "alpha")
writeFile(second, "beta")
var pairRuns = 0
proc pair(): string = siblings.get("pair", proc(): string =
  inc pairRuns
  siblings.get("first", proc(): string = siblings.input(first)) & ":" &
    siblings.get("second", proc(): string = siblings.input(second)))
doAssert pair() == "alpha:beta" and siblings.dependencies("pair").len == 2
writeFile(first, "bravo")
doAssert pair() == "bravo:beta" and pairRuns == 2
writeFile(second, "charlie")
doAssert pair() == "bravo:charlie" and pairRuns == 3

let presence = queries()
let optional = root / "optional.iv"
doAssert not presence.present(optional)
proc optionalvalue(): string = presence.get("optional", proc(): string =
  if presence.present(optional): presence.input(optional) else: "absent")
doAssert optionalValue() == "absent"
writeFile(optional, "created")
doAssert presence.present(optional)
doAssert optionalValue() == "created"
removeFile(optional)
doAssert not presence.present(optional)
doAssert optionalValue() == "absent"

var failed = false
try:
  discard presence.get("failed", proc(): string =
    discard presence.input(optional)
    raise newException(ValueError, "injected query failure"))
except ValueError: failed = true
doAssert failed and presence.dependencies("failed").len == 0
doAssert presence.get("failed", proc(): string = "recovered") == "recovered"

var fallbackRuns = 0
proc fallback(): string = presence.get("fallback", proc(): string =
  inc fallbackRuns
  try:
    discard presence.get("unstable", proc(): string =
      discard presence.input(optional)
      raise newException(ValueError, "injected child failure"))
  except ValueError:
    discard
  "fallback")
doAssert fallback() == "fallback" and fallbackRuns == 1
writeFile(optional, "arrived")
doAssert fallback() == "fallback" and fallbackRuns == 2

removeDir(root)
echo "build query parity: ok"
