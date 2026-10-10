import std/[json, os, tables]
import ../../src/build/project

let root = getTempDir() / "foo-build-project-actual-test"
putEnv("ZIG_GLOBAL_CACHE_DIR", absolutePath(".artifacts/cache/zig"))
putEnv("ZIG_LOCAL_CACHE_DIR", absolutePath(".artifacts/cache/local"))
if dirExists(root): removeDir(root)
createDir(root / "src")
writeFile(root / "src" / "core.iv", """public define Reference as record {
  number of type integer.
}.
""")
writeFile(root / "src" / "store.iv", """use map as maps.
use core.

public define Store as record {
  values of type maps.dictionary[text, core.Reference].
}.
""")
writeFile(root / "src" / "main.iv", """use store.
start { give nothing. }
""")
writeFile(root / "project.json", """{"name":"actual","language":"1","version":"0.1.0","source":"src","entry":"src/main.iv","requires":"base"}""")
let products = newProject(root).build()
doAssert products.hasKey("app")
doAssert fileExists(products["app"])
doAssert parentDir(products["app"]) == root / "output"
doAssert fileExists(root / ".artifacts" / "build" / products["app"].lastPathPart)
var manifest = parseJson(readFile(root / "project.json"))
manifest["build"] = %*{"output": "dist"}
writeFile(root / "project.json", $manifest)
let cproducts = newProject(root, ProjectOptions(backend: "c")).build()
doAssert cproducts.hasKey("app")
doAssert fileExists(cproducts["app"])
doAssert parentDir(cproducts["app"]) == root / "dist"
removeFile(cproducts["app"])
let restored = newProject(root, ProjectOptions(backend: "c")).build()
doAssert restored["app"] == cproducts["app"]
doAssert fileExists(restored["app"])
removeDir(root)

let libraryRoot = getTempDir() / "foo-build-library-output-test"
if dirExists(libraryRoot): removeDir(libraryRoot)
createDir(libraryRoot / "src")
writeFile(libraryRoot / "src" / "library.iv", """public define Reference as record {
  number of type integer.
}.
""")
writeFile(libraryRoot / "project.json", """{"name":"libraries","language":"1","version":"0.1.0","source":"src","requires":"base","build":{"output":"output","products":{"archive":{"entry":"src/library.iv","kind":"static"},"shared":{"entry":"src/library.iv","kind":"shared"}}}}""")
let libraries = newProject(libraryRoot, ProjectOptions(backend: "c")).build()
doAssert libraries.len == 2
doAssert parentDir(libraries["archive"]) == libraryRoot / "output"
doAssert parentDir(libraries["shared"]) == libraryRoot / "output"
doAssert fileExists(libraries["archive"])
doAssert fileExists(libraries["shared"])
doAssert fileExists(libraryRoot / ".artifacts" / "build" / "archive" /
  libraries["archive"].lastPathPart)
doAssert fileExists(libraryRoot / ".artifacts" / "build" / "shared" /
  libraries["shared"].lastPathPart)
removeDir(libraryRoot)
echo "actual multi-module project build parity: ok"
