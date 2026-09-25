import std/[json, os, strutils]
import ../../src/cli/project

let root = getTempDir() / "foo-cli-project-test"
if dirExists(root): removeDir(root)
let projectRoot = create(root / "demo-app")
doAssert fileExists(projectRoot / "project.json")
doAssert fileExists(projectRoot / "src" / "main.iv")
doAssert readFile(projectRoot / "src" / "main.iv") == "display \"Hello, world!\".\n"
dependency("add", "std/testing", "1.0.0", projectRoot)
var manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert manifest["dependencies"]["std/testing"].getStr() == "1.0.0"
dependency("remove", "std/testing", root = projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert not manifest["dependencies"].hasKey("std/testing")
dependency("add", "std/ranges", "^1.2.0", projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert manifest["dependencies"]["std/ranges"].getStr() == "^1.2.0"
manifest["devDependencies"] = %*{"std/dev": "~1.0.0"}
writeFile(projectRoot / "project.json", $manifest)
dependency("remove", "std/dev", root = projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert not manifest["devDependencies"].hasKey("std/dev")
dependency("remove", "std/ranges", root = projectRoot)
dependency("add", "local/library", "..\\library", projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert manifest["dependencies"]["local/library"].getStr() == "path+../library"
dependency("remove", "local/library", root = projectRoot)
dependency("add", "acme/git", "https://example.com/acme/git.git#0123456789012345678901234567890123456789", projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert manifest["dependencies"]["acme/git"].getStr().startsWith("git+https://")
createDir(projectRoot / ".artifacts" / "build")
writeFile(projectRoot / ".artifacts" / "build" / "artifact", "x")
clean(projectRoot)
doAssert not dirExists(projectRoot / ".artifacts" / "build")
removeDir(projectRoot)

let currentRoot = root / "current-app"
createDir(currentRoot)
let previous = getCurrentDir()
setCurrentDir(currentRoot)
try:
  doAssert create(".") == currentRoot
  doAssert fileExists(currentRoot / "project.json")
  doAssert fileExists(currentRoot / "src" / "main.iv")
  var rejected = false
  try: discard create(".")
  except ValueError: rejected = true
  doAssert rejected
finally:
  setCurrentDir(previous)
removeDir(currentRoot)

let packageRoot = createPackage(root / "foo-example")
doAssert fileExists(packageRoot / "README.md")
doAssert fileExists(packageRoot / "src" / "main.iv")
let packageManifest = parseJson(readFile(packageRoot / "project.json"))
doAssert packageManifest["name"].getStr() == "foo-example"
doAssert packageManifest["repository"].getStr().endsWith("/foo-example")
doAssert readFile(packageRoot / ".gitignore").contains(".foo/")
removeDir(packageRoot)
removeDir(root)
echo "cli project parity: ok"
