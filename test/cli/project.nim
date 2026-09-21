import std/[json, os]
import ../../src/cli/project

let root = getTempDir() / "foo-cli-project-test"
if dirExists(root): removeDir(root)
let projectRoot = create(root / "demo-app")
doAssert fileExists(projectRoot / "project.json")
doAssert fileExists(projectRoot / "main.iv")
dependency("add", "std/testing", "registry+std/testing@1.0.0", projectRoot)
var manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert manifest["dependencies"]["std/testing"].getStr() == "registry+std/testing@1.0.0"
dependency("remove", "std/testing", root = projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert not manifest["dependencies"].hasKey("std/testing")
createDir(projectRoot / ".artifacts" / "build")
writeFile(projectRoot / ".artifacts" / "build" / "artifact", "x")
clean(projectRoot)
doAssert not dirExists(projectRoot / ".artifacts" / "build")
removeDir(projectRoot)
echo "cli project parity: ok"
