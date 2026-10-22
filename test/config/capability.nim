import std/[json, os, strutils]
import ../../src/config/source
import ../../src/config/capability
import ../../src/config/project as manifests

let root = getTempDir() / "foo-config-capability-test"
if dirExists(root): removeDir(root)
createDir(root / ".cap")
writeFile(root / ".cap" / "network.cap", """
namespace is "network"
version is 1
fields {
  port {
    type is "integer"
    required enable
    min is 1
    max is 65535
  }
  endpoint {
    type is "string"
    default is "127.0.0.1"
    aliases is ["host"]
  }
  large {
    type is "integer"
    max is 9007199254740992
  }
}
""")
writeFile(root / "project.ivc", """
capability "project"
capability "network"
project {
  name is "demo"
  version is "1.0.0"
}
network { port is 8080 }
""")
let project = manifests.readProject(root)
doAssert project["name"].getStr() == "demo"
doAssert project["language"].getStr() == "1"
doAssert project["requires"].getStr() == "base"
doAssert project["dependencies"].kind == JObject
doAssert not project.hasKey("network")
doAssert not dirExists(root / ".artifacts")
let doc = source.load(root / "project.ivc")
discard capability.resolve(root, doc)
doAssert doc.values["network"]["endpoint"].getStr() == "127.0.0.1"
doAssert manifests.manifestFiles(root).len == 3
doAssert fileExists(root / ".artifacts" / ".cap" / "project.cap")
doAssert fileExists(root / ".artifacts" / ".cap" / "network.cap")
doAssert capability.read(root / ".artifacts" / ".cap" / "project.cap").namespace == "project"
doAssert manifests.manifestFiles(root)[2].endsWith(".artifacts" / ".cap" / "network.cap")
let first = manifests.fingerprint(root)
let imagePath = manifests.emitImage(root)
doAssert fileExists(imagePath)
doAssert readFile(imagePath).startsWith("FCOI")
let firstImage = readFile(imagePath)
discard manifests.emitImage(root)
doAssert readFile(imagePath) == firstImage

proc reject(fragment, expected: string) =
  let original = readFile(root / "project.ivc")
  writeFile(root / "project.ivc", original.replace("port is 8080", fragment))
  try:
    discard manifests.readProject(root)
    doAssert false, "accepted " & fragment
  except CatchableError as error:
    doAssert expected in error.msg, error.msg
  writeFile(root / "project.ivc", original)

reject("port is 0", "outside its permitted range")
reject("port is 8080\n  large is 9007199254740993", "outside its permitted range")
reject("port is \"8080\"", "wrong type")
reject("host is \"x\"", "missing 'network.port'")
reject("port is 8080\n  unknown is 1", "unknown field")

let cap = capability.read(root / ".cap" / "network.cap")
doAssert cap.namespace == "network"
try:
  discard capability.read(root / ".cap" / "network.ivc")
  doAssert false, "accepted a capability definition named .ivc"
except ValueError as error:
  doAssert ".cap extension" in error.msg
writeFile(root / ".cap" / "feature.cap", """
namespace is "feature"
version is 1
requires is ["network"]
fields {}
""")
let originalProject = readFile(root / "project.ivc")
let originalCap = readFile(cap.path)
writeFile(root / "project.ivc", originalProject.replace(
  "capability \"network\"", "capability \"network\"\ncapability \"feature\"\nfeature {}"))
writeFile(cap.path, originalCap.replace("fields {", "requires is [\"feature\"]\nfields {"))
try:
  discard manifests.readProject(root)
  doAssert false, "accepted capability dependency cycle"
except ValueError as error:
  doAssert "dependency cycle" in error.msg
writeFile(root / "project.ivc", originalProject)
writeFile(cap.path, originalCap)
writeFile(root / ".cap" / "network.cap", readFile(cap.path).replace(
  "aliases is [\"host\"]", "aliases is [\"port\"]"))
try:
  discard manifests.readProject(root)
  doAssert false, "accepted conflicting alias"
except ValueError as error:
  doAssert "conflicting field or alias" in error.msg
discard first

removeDir(root)
echo "Configuration capabilities: ok"
