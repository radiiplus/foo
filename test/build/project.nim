import std/[json, os]
import ../../src/build/project

let root = getTempDir() / "foo-build-project-test"
if dirExists(root): removeDir(root)
createDir(root / "src")
writeFile(root / "src" / "main.iv", "start() { give nothing. }")
writeFile(root / "project.json", "{\"name\":\"demo\",\"language\":\"1\",\"version\":\"0.1.0\",\"source\":\"src\"}")
let p = newProject(root)
doAssert p.files().len == 1
doAssert p.manifest().name == "demo"
doAssert p.graph()["format"].getStr() == "foo.graph"
p.check()
doAssert p.ir().funcs.len == 1
removeDir(root)
echo "build project parity: ok"
