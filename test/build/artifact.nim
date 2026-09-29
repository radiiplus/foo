import std/[os, tables]
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
  values of type maps.Map[text, core.Reference].
}.
""")
writeFile(root / "src" / "main.iv", """use store.
start { give nothing. }
""")
writeFile(root / "project.json", """{"name":"actual","language":"1","version":"0.1.0","source":"src","entry":"src/main.iv","requires":"base"}""")
let products = newProject(root).build()
doAssert products.hasKey("app")
doAssert fileExists(products["app"])
let cproducts = newProject(root, ProjectOptions(backend: "c")).build()
doAssert cproducts.hasKey("app")
doAssert fileExists(cproducts["app"])
removeDir(root)
echo "actual multi-module project build parity: ok"
