import std/[json, os, osproc, strutils]
import ../../src/cli/project
import ../../src/pkg/registry
import ../../src/config/project as configuration

let root = getTempDir() / "foo-registry-publish"
if dirExists(root): removeDir(root)
discard package(root)
var manifest = configuration.readProject(root)
manifest["description"] = %"A package used to test publication."
manifest["category"] = %"developer tools"
manifest["repository"] = %"https://github.com/example/foo-registry-publish"
configuration.writeProject(root, manifest)
var documentation = "# foo-registry-publish\n"
for index in 1 .. 100: documentation.add("Documentation line " & $index & ".\n")
writeFile(root / "README.md", documentation)
writeFile(root / "icon.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M0 0\"/></svg>")
manifest["icon"] = %"icon.svg"
configuration.writeProject(root, manifest)
writeFile(root / "src" / "main.iv",
  "-- Exposes the package version.\npublic constant version is \"0.1.0\".\n")

proc run(arguments: string): string =
  let response = execCmdEx("git -C " & quoteShell(root) & " " & arguments)
  doAssert response.exitCode == 0, response.output
  response.output.strip

discard run("init --quiet")
discard run("config user.name foo-test")
discard run("config user.email foo-test@example.invalid")
discard run("add .")
discard run("commit --quiet -m initial")
let revision = run("rev-parse HEAD")
var submitted: JsonNode
var events: seq[string]
transport(proc(config: Registry; path, methodName, body, token: string): Response =
  discard config
  doAssert path == "/publish"
  doAssert methodName == "POST"
  doAssert token == "github-token"
  submitted = parseJson(body)
  Response(status: 201, body: "{\"package\":\"foo-registry-publish\",\"version\":\"0.1.0\",\"commit\":\"0123456789abcdef0123456789abcdef01234567\"}")
)

doAssert publish(root, "github-token", proc(phase, name, detail: string) =
  events.add(phase & ":" & name & ":" & detail)) == "foo-registry-publish@0.1.0"
doAssert events == @[
  "package:foo-registry-publish@0.1.0:revision " & revision[0 .. 11],
  "bundle:foo-registry-publish@0.1.0:3 files, 1 exports, 101 documentation lines",
  "upload:foo-registry-publish@0.1.0:" & defaultApi,
  "commit:foo-registry-publish@0.1.0:0123456789ab",
], $events
doAssert submitted["manifest"]["revision"].getStr() == revision
doAssert submitted["documentation"].len == 101
doAssert submitted["icon"].getStr().contains("<path")
doAssert not submitted["manifest"].hasKey("owner")
doAssert submitted["source"]["format"].getStr() == "foo.source/v1"
doAssert submitted["source"]["digest"].getStr().len == 64
doAssert submitted["source"]["files"].len >= 2
doAssert submitted["api"]["schema"].getStr() == "foo.api/v1"
doAssert submitted["api"]["modules"].len >= 1
doAssert submitted["api"]["modules"][0]["items"][0]["documentation"].getStr() ==
  "Exposes the package version."
doAssert readFile(root / "README.md") == documentation

var external = configuration.readProject(root)
external["dependencies"] = %*{"local": "path+../local"}
configuration.writeProject(root, external)
discard run("add project.ivc")
discard run("commit --quiet -m external")
var rejected = false
try:
  discard publish(root, "github-token")
except ValueError as error:
  rejected = error.msg.contains("must use registry versions")
doAssert rejected
removeDir(root)
echo "pkg registry publication: ok"
