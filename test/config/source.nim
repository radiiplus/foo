import std/[json, os, strutils]
import ../../src/config/source
import ../../src/config/project as manifests

let root = getTempDir() / "foo-config-source-test"
if dirExists(root): removeDir(root)
createDir(root)

writeFile(root / "shared.ivc", """
project {
  build {
    cpu using native
    output is "old-output"
  }
  dependencies { imported is "1.0.0" }
}
""")
writeFile(root / "project.ivc", """
capability "project"
import "shared.ivc"
project {
  name is "demo"
  version is "1.0.0"
  build {
    output is "output"
    debug disable
    target is ["linux-x64", "windows-x64"]
  }
}
""")
let loaded = manifests.readProject(root)
doAssert loaded["name"].getStr() == "demo"
doAssert loaded["schema"].getInt() == 1
doAssert loaded["language"].getStr() == "1"
doAssert loaded["requires"].getStr() == "base"
doAssert loaded["build"]["cpu"].getStr() == "native"
doAssert loaded["build"]["output"].getStr() == "output"
doAssert not loaded["build"]["debug"].getBool()
doAssert manifests.manifestFiles(root).len == 3

loaded["build"]["output"] = %"second-output"
manifests.writeProject(root, loaded)
doAssert manifests.readProject(root)["build"]["output"].getStr() == "second-output"
doAssert manifests.fingerprint(root).len == 64
loaded["dependencies"]["added"] = %"2.0.0"
manifests.writeProject(root, loaded)
doAssert readFile(root / "project.ivc").contains("import \"shared.ivc\"")
doAssert manifests.readProject(root)["dependencies"]["added"].getStr() == "2.0.0"
doAssert manifests.manifestFiles(root).len == 3

writeFile(root / "units.ivc", """
memory {
  decimal is 1000MB
  binary is 1GiB
  timeout is 5ms
  enabled enable
  values is [1, 2, { item is "x" }]
}
products "server" { entry is "src/main.iv" }
""")
let values = source.load(root / "units.ivc").values
doAssert source.loadText("settings { port is 1 }\nsettings { port is 2 }\n",
  root / "layers.ivc").values["settings"]["port"].getInt() == 2
doAssert values["format"].getInt() == 1
doAssert values["memory"]["decimal"].getInt() == 1000000000
doAssert values["memory"]["binary"].getInt() == 1073741824
doAssert values["memory"]["timeout"].getInt() == 5000000
doAssert values["memory"]["enabled"].getBool()
doAssert values["memory"]["values"][2]["item"].getStr() == "x"
doAssert values["products"]["server"]["entry"].getStr() == "src/main.iv"

proc rejects(file, text, expected: string) =
  writeFile(root / file, text)
  try:
    discard source.load(root / file)
    doAssert false, "accepted " & file
  except CatchableError as error:
    doAssert expected in error.msg, error.msg

rejects("format.ivc", "format is 1\n", "format is assigned")
rejects("duplicate.ivc", "name is \"a\"\nname is \"b\"\n",
  "duplicate 'name'")
rejects("duplicate-block.ivc", "settings { port is 1 port is 2 }\n",
  "duplicate 'settings.port'")
rejects("unit.ivc", "size is 1XB\n", "unknown unit")
rejects("overflow.ivc", "size is 9223372036854775807GiB\n",
  "quantity overflows")
rejects("missing.ivc", "import \"absent.ivc\"\n",
  "not found")
rejects("escape.ivc", "import \"../outside.ivc\"\n",
  "escapes root")
writeFile(root / "other.ivc", "import \"cycle.ivc\"\n")
rejects("cycle.ivc", "import \"other.ivc\"\n",
  "import cycle")

removeDir(root)
echo "Configuration source: ok"
