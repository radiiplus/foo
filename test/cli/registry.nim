import std/[json, os, osproc, strutils]
import ../../src/cli/main as cli
import ../../src/cli/project
import ../../src/pkg/registry

let originalDirectory = getCurrentDir()
let originalConfig = getEnv("FOO_CONFIG_DIR")
let root = getTempDir() / "foo-cli-registry-test"
let config = getTempDir() / "foo-cli-registry-config"

proc removeTree(path: string) =
  if not dirExists(path): return
  for kind, child in walkDir(path):
    if kind == pcDir: removeTree(child)
    else: removeFile(child)
  removeDir(path)

proc git(arguments: varargs[string]): string =
  var command = "git -C " & quoteShell(root)
  for argument in arguments: command.add(" " & quoteShell(argument))
  let response = execCmdEx(command)
  doAssert response.exitCode == 0, response.output
  response.output.strip

removeTree(root)
removeTree(config)
discard createPackage(root)
var manifest = parseJson(readFile(root / "project.json"))
manifest["description"] = %"A package published through the Foo CLI test."
manifest["category"] = %"developer tools"
manifest["repository"] = %"https://github.com/example/foo-cli-registry-test"
writeFile(root / "project.json", pretty(manifest) & "\n")
var documentation = "# foo-cli-registry-test\n"
for index in 1 .. 100: documentation.add("Documentation line " & $index & ".\n")
writeFile(root / "README.md", documentation)

discard git("init", "--quiet")
discard git("config", "user.name", "foo-test")
discard git("config", "user.email", "foo-test@example.invalid")
discard git("add", ".")
discard git("commit", "--quiet", "-m", "initial")

var submitted: JsonNode
var devicePolls = 0
var openedUrl = ""
setRegistryBrowserOpener(proc(url: string) = openedUrl = url)
setRegistryTransport(proc(config: Registry; path, methodName, body, token: string): RegistryResponse =
  discard config
  case path
  of "/auth/device":
    doAssert methodName == "POST"
    doAssert token.len == 0
    RegistryResponse(status: 200, body: $(%*{
      "device_code": "device-code",
      "user_code": "ABCD-1234",
      "verification_uri": "https://github.com/login/device",
      "expires_in": 30,
      "interval": 0,
    }))
  of "/auth/device/token":
    inc devicePolls
    doAssert parseJson(body)["device_code"].getStr() == "device-code"
    RegistryResponse(status: 200, body: "{\"access_token\":\"github-token\"}")
  of "/publish":
    doAssert methodName == "POST"
    doAssert token == "github-token"
    submitted = parseJson(body)
    RegistryResponse(status: 201, body: "{\"package\":\"foo-cli-registry-test\",\"version\":\"0.1.0\"}")
  else:
    RegistryResponse(status: 404, body: "{\"error\":\"not found\"}")
)

try:
  putEnv("FOO_CONFIG_DIR", config)
  setCurrentDir(root)
  doAssert cli.main(@["login"]) == 0
  doAssert openedUrl == "https://github.com/login/device"
  doAssert devicePolls == 1
  doAssert parseJson(readFile(config / "auth.json"))["access_token"].getStr() == "github-token"
  doAssert cli.main(@["publish"]) == 0
  doAssert submitted["schema"].getStr() == "foo.publish/v1"
  doAssert submitted["source"]["digest"].getStr().len == 64
  doAssert submitted["api"]["schema"].getStr() == "foo.api/v1"
  doAssert submitted["api"]["modules"].len >= 1
finally:
  setRegistryBrowserOpener(nil)
  setRegistryTransport(nil)
  setCurrentDir(originalDirectory)
  if originalConfig.len > 0: putEnv("FOO_CONFIG_DIR", originalConfig)
  else: delEnv("FOO_CONFIG_DIR")
  removeTree(root)
  removeTree(config)

echo "cli registry authentication and publication: ok"
