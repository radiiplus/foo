import std/[json, os, strutils]
import ../../src/cli/project
import ../../src/config/project as manifests

let root = getTempDir() / "foo-cli-project-test"
if dirExists(root): removeDir(root)
let checkout = create(root / "demo-app")
doAssert fileExists(checkout / "project.ivc")
doAssert fileExists(checkout / "src" / "main.iv")
doAssert fileExists(checkout / "test" / "main.iv")
doAssert fileExists(checkout / "benchmark" / "main.iv")
doAssert fileExists(checkout / "assets" / "icon.ico")
doAssert fileExists(checkout / "assets" / "icon.svg")
doAssert readFile(checkout / "src" / "main.iv") == "display \"Hello, world!\".\n"
for field in ["format is", "schema is", "language is", "requires is"]:
  doAssert field notin readFile(checkout / "project.ivc")
let metadata = manifests.readProject(checkout)
doAssert metadata["schema"].getInt() == 1
doAssert metadata["language"].getStr() == "1"
doAssert metadata["requires"].getStr() == "base"
doAssert metadata["entry"].getStr() == "src/main.iv"
doAssert metadata["entries"].kind == JObject
doAssert metadata["build"]["output"].getStr() == "output"
doAssert not metadata["build"].hasKey("icon")
doAssert readFile(checkout / ".gitignore").contains("output/")
dependency("add", "lib/testing", "1.0.0", checkout)
var manifest = manifests.readProject(checkout)
doAssert manifest["dependencies"]["lib/testing"].getStr() == "1.0.0"
dependency("remove", "lib/testing", root = checkout)
manifest = manifests.readProject(checkout)
doAssert not manifest["dependencies"].hasKey("lib/testing")
dependency("add", "lib/ranges", "^1.2.0", checkout)
manifest = manifests.readProject(checkout)
doAssert manifest["dependencies"]["lib/ranges"].getStr() == "^1.2.0"
manifest["devDependencies"] = %*{"lib/dev": "~1.0.0"}
manifests.writeProject(checkout, manifest)
dependency("remove", "lib/dev", root = checkout)
manifest = manifests.readProject(checkout)
doAssert not manifest["devDependencies"].hasKey("lib/dev")
dependency("remove", "lib/ranges", root = checkout)
dependency("add", "local/library", "..\\library", checkout)
manifest = manifests.readProject(checkout)
doAssert manifest["dependencies"]["local/library"].getStr() == "path+../library"
dependency("remove", "local/library", root = checkout)
dependency("add", "acme/git", "https://example.com/acme/git.git#0123456789012345678901234567890123456789", checkout)
manifest = manifests.readProject(checkout)
doAssert manifest["dependencies"]["acme/git"].getStr().startsWith("git+https://")
createDir(checkout / ".artifacts" / "build")
writeFile(checkout / ".artifacts" / "build" / "artifact", "x")
createDir(checkout / "output")
writeFile(checkout / "output" / "app", "x")
let image = manifests.emitImage(checkout)
doAssert fileExists(image)
clean(checkout)
doAssert not dirExists(checkout / ".artifacts" / "build")
doAssert not dirExists(checkout / ".artifacts" / ".cap")
doAssert not dirExists(checkout / "output")
doAssert not fileExists(image)
manifest = manifests.readProject(checkout)
manifest["build"] = %*{"output": "dist/native"}
manifests.writeProject(checkout, manifest)
createDir(checkout / "dist" / "native")
writeFile(checkout / "dist" / "native" / "app", "x")
clean(checkout)
doAssert not dirExists(checkout / "dist" / "native")
removeDir(checkout)

let workspace = root / "current-app"
createDir(workspace)
let previous = getCurrentDir()
setCurrentDir(workspace)
try:
  doAssert create(".") == workspace
  doAssert fileExists(workspace / "project.ivc")
  doAssert fileExists(workspace / "src" / "main.iv")
  doAssert dirExists(workspace / "test")
  doAssert dirExists(workspace / "benchmark")
  doAssert fileExists(workspace / "assets" / "icon.ico")
  var rejected = false
  try: discard create(".")
  except ValueError: rejected = true
  doAssert rejected
finally:
  setCurrentDir(previous)
removeDir(workspace)

let repository = package(root / "foo-example")
doAssert fileExists(repository / "README.md")
doAssert fileExists(repository / "src" / "main.iv")
doAssert dirExists(repository / "test")
doAssert dirExists(repository / "benchmark")
let document = manifests.readProject(repository)
doAssert document["name"].getStr() == "foo-example"
doAssert document["repository"].getStr().endsWith("/foo-example")
doAssert readFile(repository / ".gitignore").contains(".foo/")
removeDir(repository)
removeDir(root)
echo "cli project parity: ok"
