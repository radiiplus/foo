import std/[os, strutils]
import ../../src/cli/project as scaffold
import ../../src/cli/link as commands
import ../../src/build/project

let root = getTempDir() / "foo-cli-link-test"
if dirExists(root): removeDir(root)
let projectRoot = scaffold.create(root / "linked-app")
let bin = root / "bin"
putEnv("FOO_BIN", bin)

let launcher = commands.install(newProject(projectRoot))
doAssert fileExists(launcher)
doAssert launcher.parentDir == bin
doAssert readFile(launcher).contains(projectRoot)
when defined(windows):
  doAssert launcher.lastPathPart == "linked-app.cmd"
  doAssert readFile(launcher).contains(" -- %*")
else:
  doAssert launcher.lastPathPart == "linked-app"
  doAssert readFile(launcher).contains(" -- \"$@\"")

let removed = commands.remove("linked-app")
doAssert removed == launcher
doAssert not fileExists(launcher)
delEnv("FOO_BIN")
removeDir(root)
echo "cli command link parity: ok"
