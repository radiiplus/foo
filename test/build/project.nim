import std/[json, os, sequtils]
import ../../src/build/project

let root = getTempDir() / "foo-build-project-test"
if dirExists(root): removeDir(root)
createDir(root / "src")
writeFile(root / "src" / "main.iv", "start() { give nothing. }")
writeFile(root / "project.json", "{\"name\":\"demo\",\"language\":\"1\",\"version\":\"0.1.0\",\"license\":\"MIT OR Apache-2.0\",\"source\":\"src\"}")
let p = newProject(root)
doAssert p.files().len == 1
doAssert p.manifest().name == "demo"
doAssert p.manifest().license == "MIT OR Apache-2.0"
doAssert p.graph()["format"].getStr() == "foo.graph"
p.check()
doAssert p.ir().funcs.len == 1

writeFile(root / "src" / "main.iv", "display \"top level\".")
let concise = newProject(root)
concise.check()
doAssert concise.ir().funcs.anyIt(it.name == "main")
removeDir(root)
echo "build project parity: ok"
