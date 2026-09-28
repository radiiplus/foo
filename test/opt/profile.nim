import std/[os, sets, tables]
import ../../src/opt/profile

let path = getTempDir() / "foo-optimization-profile.json"
writeFile(path, """{"version":1,"kind":"function","entries":[{"function":"parse","line":4,"hits":100},{"function":"cold","line":9,"hits":1},{"function":"parse","line":4,"hits":20}]}""")
let counts = load(path)
doAssert counts["parse"] == 120
doAssert counts["cold"] == 1
let selected = hot(counts)
doAssert "parse" in selected
doAssert "cold" notin selected

writeFile(path, "{}")
var rejected = false
try: discard load(path)
except ValueError: rejected = true
doAssert rejected

writeFile(path, """{"version":"1","kind":"function","entries":[]}""")
rejected = false
try: discard load(path)
except ValueError: rejected = true
doAssert rejected

writeFile(path, """{"version":1,"kind":"function","entries":[{"function":"hot","hits":9223372036854775807},{"function":"hot","hits":9223372036854775807},{"function":"hot","hits":2}]}""")
rejected = false
try: discard load(path)
except ValueError: rejected = true
doAssert rejected
removeFile(path)
echo "optimization profile parity: ok"
