import std/[os, tables]
import ../../src/build/project

let root = getTempDir() / "foo-build-project-actual-test"
putEnv("ZIG_GLOBAL_CACHE_DIR", absolutePath(".artifacts/cache/zig"))
putEnv("ZIG_LOCAL_CACHE_DIR", absolutePath(".artifacts/cache/local"))
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "main.iv", "start() { give nothing. }")
writeFile(root / "project.json", "{\"name\":\"actual\",\"language\":\"1\",\"version\":\"0.1.0\"}")
let products = newProject(root).build()
doAssert products.hasKey("app")
doAssert fileExists(products["app"])
removeDir(root)
echo "actual project build parity: ok"
