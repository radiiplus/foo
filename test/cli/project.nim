import std/[json, os, strutils]
import ../../src/cli/project

let root = getTempDir() / "foo-cli-project-test"
if dirExists(root): removeDir(root)
let projectRoot = create(root / "demo-app")
doAssert fileExists(projectRoot / "project.json")
doAssert fileExists(projectRoot / "src" / "main.iv")
doAssert fileExists(projectRoot / "test" / "main.iv")
doAssert fileExists(projectRoot / "benchmark" / "main.iv")
doAssert fileExists(projectRoot / "assets" / "icon.ico")
doAssert fileExists(projectRoot / "assets" / "icon.svg")
doAssert readFile(projectRoot / "src" / "main.iv") == "display \"Hello, world!\".\n"
let generatedManifest = parseJson(readFile(projectRoot / "project.json"))
doAssert generatedManifest["entry"].getStr() == "src/main.iv"
doAssert generatedManifest["entries"].kind == JObject
doAssert generatedManifest["build"]["output"].getStr() == "output"
doAssert generatedManifest["build"]["icon"].getStr() == "assets/icon.ico"
doAssert readFile(projectRoot / ".gitignore").contains("output/")
dependency("add", "lib/testing", "1.0.0", projectRoot)
var manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert manifest["dependencies"]["lib/testing"].getStr() == "1.0.0"
dependency("remove", "lib/testing", root = projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert not manifest["dependencies"].hasKey("lib/testing")
dependency("add", "lib/ranges", "^1.2.0", projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert manifest["dependencies"]["lib/ranges"].getStr() == "^1.2.0"
manifest["devDependencies"] = %*{"lib/dev": "~1.0.0"}
writeFile(projectRoot / "project.json", $manifest)
dependency("remove", "lib/dev", root = projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert not manifest["devDependencies"].hasKey("lib/dev")
dependency("remove", "lib/ranges", root = projectRoot)
dependency("add", "local/library", "..\\library", projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert manifest["dependencies"]["local/library"].getStr() == "path+../library"
dependency("remove", "local/library", root = projectRoot)
dependency("add", "acme/git", "https://example.com/acme/git.git#0123456789012345678901234567890123456789", projectRoot)
manifest = parseJson(readFile(projectRoot / "project.json"))
doAssert manifest["dependencies"]["acme/git"].getStr().startsWith("git+https://")
createDir(projectRoot / ".artifacts" / "build")
writeFile(projectRoot / ".artifacts" / "build" / "artifact", "x")
createDir(projectRoot / "output")
writeFile(projectRoot / "output" / "app", "x")
clean(projectRoot)
doAssert not dirExists(projectRoot / ".artifacts" / "build")
doAssert not dirExists(projectRoot / "output")
manifest = parseJson(readFile(projectRoot / "project.json"))
manifest["build"] = %*{"output": "dist/native"}
writeFile(projectRoot / "project.json", $manifest)
createDir(projectRoot / "dist" / "native")
writeFile(projectRoot / "dist" / "native" / "app", "x")
clean(projectRoot)
doAssert not dirExists(projectRoot / "dist" / "native")
removeDir(projectRoot)

let currentRoot = root / "current-app"
createDir(currentRoot)
let previous = getCurrentDir()
setCurrentDir(currentRoot)
try:
  doAssert create(".") == currentRoot
  doAssert fileExists(currentRoot / "project.json")
  doAssert fileExists(currentRoot / "src" / "main.iv")
  doAssert dirExists(currentRoot / "test")
  doAssert dirExists(currentRoot / "benchmark")
  doAssert fileExists(currentRoot / "assets" / "icon.ico")
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
doAssert dirExists(packageRoot / "test")
doAssert dirExists(packageRoot / "benchmark")
let packageManifest = parseJson(readFile(packageRoot / "project.json"))
doAssert packageManifest["name"].getStr() == "foo-example"
doAssert packageManifest["repository"].getStr().endsWith("/foo-example")
doAssert readFile(packageRoot / ".gitignore").contains(".foo/")
removeDir(packageRoot)
removeDir(root)
echo "cli project parity: ok"
