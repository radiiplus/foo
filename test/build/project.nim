import std/[json, os, sequtils, sets]
import ../../src/build/project

let root = getTempDir() / "foo-build-project-test"
if dirExists(root): removeDir(root)
createDir(root / "src")
writeFile(root / "src" / "main.iv", "start { give nothing. }")
writeFile(root / "project.json", "{\"name\":\"demo\",\"language\":\"1\",\"version\":\"0.1.0\",\"license\":\"MIT OR Apache-2.0\",\"source\":\"src\"}")
let p = newProject(root)
doAssert compilerIdentity().len == 64
let release = newProject(root, ProjectOptions(mode: "release")).compiler()
doAssert release.mode == "release"
doAssert release.optimization
var invalidMode = false
try: discard newProject(root, ProjectOptions(mode: "fast")).compiler()
except ValueError: invalidMode = true
doAssert invalidMode
let development = buildIdentity("project", "compiler-a", "c", "x86_64-windows",
  "src/main.iv", "dev", "native", false)
doAssert development != buildIdentity("project", "compiler-b", "c",
  "x86_64-windows", "src/main.iv", "dev", "native", false)
doAssert development != buildIdentity("project", "compiler-a", "c",
  "x86_64-windows", "src/main.iv", "release", "native", false)
doAssert development != buildIdentity("project", "compiler-a", "c",
  "x86_64-windows", "src/main.iv", "dev", "native", true)
doAssert p.files().len == 1
doAssert p.manifest().name == "demo"
doAssert p.manifest().license == "MIT OR Apache-2.0"
doAssert p.graph()["format"].getStr() == "foo.graph"
p.check()
doAssert p.ir().funcs.len == 1

writeFile(root / "src" / "worker.iv", "display \"worker\".")
var configured = parseJson(readFile(root / "project.json"))
configured["entry"] = %"src/main.iv"
configured["entries"] = %*{"worker": "src/worker.iv"}
writeFile(root / "project.json", $configured)
let entries = newProject(root)
doAssert entries.entryPath() == absolutePath(root / "src" / "main.iv")
doAssert entries.entryPath("worker") == absolutePath(root / "src" / "worker.iv")
configured["entries"] = %*{"outside": "../outside.iv"}
writeFile(root / "project.json", $configured)
var invalidEntry = false
try: discard newProject(root).manifest()
except ValueError: invalidEntry = true
doAssert invalidEntry
configured["entries"] = %*{"worker": "src/worker.iv"}
writeFile(root / "project.json", $configured)

writeFile(root / "src" / "main.iv", "display \"top level\".")
let concise = newProject(root)
concise.check()
doAssert concise.ir().funcs.anyIt(it.name == "main")

let flat = getTempDir() / "foo-build-flat-test"
if dirExists(flat): removeDir(flat)
createDir(flat / "test")
createDir(flat / "benchmark")
writeFile(flat / "main.iv", "display \"application\".")
writeFile(flat / "test" / "suite.iv", "test \"suite\" { display \"test\". }")
writeFile(flat / "benchmark" / "speed.iv", "display \"benchmark\".")
doAssert newProject(flat).files() == @[absolutePath(flat / "main.iv")]
removeDir(flat)

writeFile(root / "profile.json",
  """{"version":1,"kind":"function","entries":[{"function":"main","line":1,"hits":50}]}""")
configured["build"] = %*{"optimize": "release", "profile": "profile.json"}
writeFile(root / "project.json", $configured)
let profiled = newProject(root)
doAssert "main" in profiled.compiler().hot
removeDir(root)
echo "build project parity: ok"
