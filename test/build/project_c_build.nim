import std/[os, tables]
import ../../src/build/project

let root = getTempDir() / "foo-build-project-c-test"
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "main.iv", "start() { give nothing. }")
writeFile(root / "project.json", "{\"name\":\"actualc\",\"language\":\"1\",\"version\":\"0.1.0\",\"build\":{\"backend\":\"c\",\"compiler\":\"clang\"}}")
var reused = false
let buildProject = newProject(root, ProjectOptions(backend: "c", progress: proc(phase, name, file: string; cached: bool) =
  discard name; discard file
  if phase == "reuse" and cached: reused = true))
let products = buildProject.build()
doAssert products.hasKey("app")
doAssert fileExists(products["app"])
discard buildProject.build()
doAssert reused
removeDir(root)
echo "actual C project build parity: ok"
