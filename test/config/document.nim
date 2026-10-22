import std/[json, os, strutils]
import ../../src/config/document

let root = getTempDir() / "foo-config-standalone-test"
if dirExists(root): removeDir(root)
createDir(root / ".cap")
let definition = root / ".cap" / "service.cap"
writeFile(definition, """
namespace is "service"
version is 1
fields {
  port { type is "integer" required enable min is 1 max is 65535 }
  secure { type is "boolean" default enable }
}
""")
writeFile(root / "service.ivc", """
capability "service"
service { port is 8443 }
""")
let validated = document.check(root / "service.ivc")
doAssert validated.values["service"]["port"].getInt() == 8443
doAssert validated.values["service"]["secure"].getBool()
let generated = root / ".artifacts" / ".cap" / "service.cap"
doAssert fileExists(generated)
doAssert readFile(generated).contains("namespace is \"service\"")
let originalDefinition = readFile(definition)
let originalGenerated = readFile(generated)
writeFile(definition, originalDefinition.replace("default enable", "default disable"))
doAssert not document.check(root / "service.ivc").values["service"]["secure"].getBool()
doAssert readFile(generated) != originalGenerated
writeFile(definition, originalDefinition)
removeFile(generated)
discard document.check(root / "service.ivc")
doAssert fileExists(generated)
doAssert readFile(generated) == originalGenerated
let output = document.emit(root / "service.ivc")
doAssert output.endsWith("service.cimg")
doAssert readFile(output).startsWith("FCOI")
let first = readFile(output)
discard document.emit(root / "service.ivc")
doAssert readFile(output) == first

writeFile(root / "service.ivc", """
capability "service"
service { port is 8443 }
secret is "undeclared"
""")
try:
  discard document.check(root / "service.ivc")
  doAssert false, "accepted a field without a capability"
except ValueError as error:
  doAssert "no selected capability defines 'secret'" in error.msg

writeFile(root / "service.ivc", """
service { port is 8443 }
""")
try:
  discard document.check(root / "service.ivc")
  doAssert false, "accepted a configuration without a selected capability"
except ValueError as error:
  doAssert "select at least one capability" in error.msg

removeDir(root)
echo "Standalone configuration capabilities: ok"
