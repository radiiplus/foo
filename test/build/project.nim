import std/[json, os, sequtils, sets, strutils]
import ../../src/build/project
import ../../src/config/project as configuration

let root = getTempDir() / "foo-build-project-test"
if dirExists(root): removeDir(root)
createDir(root / "src")
writeFile(root / "src" / "main.iv", "start { give nothing. }")
configuration.writeProject(root, %*{"name": "demo", "version": "0.1.0",
  "license": "MIT OR Apache-2.0", "source": "src"})
let p = project(root)
doAssert identity().len == 64
let release = project(root, Settings(mode: "release")).compiler()
doAssert release.mode == "release"
doAssert release.optimization
var unsupported = false
try: discard project(root, Settings(mode: "fast")).compiler()
except ValueError: unsupported = true
doAssert unsupported
let development = identity("project", "compiler-a", "c", "x86_64-windows",
  "src/main.iv", "dev", "native", false)
doAssert development != identity("project", "compiler-b", "c",
  "x86_64-windows", "src/main.iv", "dev", "native", false)
doAssert development != identity("project", "compiler-a", "c",
  "x86_64-windows", "src/main.iv", "release", "native", false)
doAssert development != identity("project", "compiler-a", "c",
  "x86_64-windows", "src/main.iv", "dev", "native", true)
doAssert p.files().len == 1
doAssert p.manifest().name == "demo"
doAssert p.manifest().license == "MIT OR Apache-2.0"
doAssert p.graph()["format"].getStr() == "foo.graph"
p.check()
doAssert p.ir().funcs.len == 1
doAssert inferredKind(host, true) == "exe"
doAssert inferredKind(host, false) == "static"
doAssert inferredKind("wasm-freestanding", false) == "object"
doAssert inferredKind("wasi", false) == "object"
doAssert inferredKind("spirv-vulkan1.3", false) == "shader"
doAssert inferredKind(host, root / "src" / "main.iv") == "exe"
let library = root / "src" / "library.iv"
writeFile(library, "public constant sample is \"start(\".\n")
doAssert inferredKind(host, library) == "static"
doAssert inferredKind("wasi", library) == "object"
removeFile(library)
var rejectedLibraryRun = false
try:
  discard project(root, Settings(kind: "static")).build(executable = true)
except ValueError as error:
  rejectedLibraryRun = error.msg.contains("Cannot run a static product")
doAssert rejectedLibraryRun
var uefiLibrary = false
try: discard inferredKind("uefi-x64", false)
except ValueError: uefiLibrary = true
doAssert uefiLibrary

writeFile(root / "src" / "worker.iv", "display \"worker\".")
var configured = configuration.readProject(root)
configured["entry"] = %"src/main.iv"
configured["entries"] = %*{"worker": "src/worker.iv"}
configuration.writeProject(root, configured)
let entries = project(root)
doAssert entries.entry() == absolutePath(root / "src" / "main.iv")
doAssert entries.entry("worker") == absolutePath(root / "src" / "worker.iv")
configured["entries"] = %*{"outside": "../outside.iv"}
configuration.writeProject(root, configured)
var malformed = false
try: discard project(root).manifest()
except ValueError: malformed = true
doAssert malformed
configured["entries"] = %*{"worker": "src/worker.iv"}
configuration.writeProject(root, configured)

writeFile(root / "src" / "main.iv", "display \"top level\".")
let concise = project(root)
concise.check()
doAssert inferredKind(host, root / "src" / "main.iv") == "exe"
doAssert concise.ir().funcs.anyIt(it.name == "main")

let flat = getTempDir() / "foo-build-flat-test"
if dirExists(flat): removeDir(flat)
createDir(flat / "test")
createDir(flat / "benchmark")
writeFile(flat / "main.iv", "display \"application\".")
writeFile(flat / "test" / "suite.iv", "test \"suite\" { display \"test\". }")
writeFile(flat / "benchmark" / "speed.iv", "display \"benchmark\".")
doAssert project(flat).files() == @[absolutePath(flat / "main.iv")]
removeDir(flat)

writeFile(root / "profile.json",
  """{"version":1,"kind":"function","entries":[{"function":"main","line":1,"hits":50}]}""")
configured["build"] = %*{"optimize": "release", "profile": "profile.json"}
configuration.writeProject(root, configured)
let profiled = project(root)
doAssert "main" in profiled.compiler().hot
configured["build"]["output"] = %"dist/native"
configuration.writeProject(root, configured)
doAssert project(root).config().output == "dist/native"
for invalid in ["src", ".artifacts/output", "../outside"]:
  configured["build"]["output"] = %invalid
  configuration.writeProject(root, configured)
  var rejected = false
  try: discard project(root).build()
  except ValueError: rejected = true
  doAssert rejected
removeDir(root)
echo "build project parity: ok"
