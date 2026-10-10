import std/[json, os, sequtils, strutils, tables]
import ../../src/cli/project as cliProject
import ../../src/pkg/[hash, registry]

let base = getTempDir() / "foo-local-install"
let root = base / "app"
let stateful = base / "stateful"
let helper = base / "helper"
if dirExists(base): removeDir(base)
createDir(root)
createDir(root / "src")
createDir(stateful / "src")
createDir(helper / "src")

writeFile(helper / "project.json", $(%*{
  "name": "helper",
  "version": "1.1.0",
  "source": "src",
  "entry": "src/main.iv",
  "dependencies": newJObject(),
}))
writeFile(helper / "src" / "main.iv", "public constant help is \"helper\".\n")
writeFile(stateful / "project.json", $(%*{
  "name": "stateful",
  "version": "0.4.0",
  "source": "src",
  "entry": "src/main.iv",
  "dependencies": {"helper": "path+../helper"},
}))
writeFile(stateful / "src" / "main.iv",
  "use helper.\npublic constant label is help.\n")
writeFile(root / "project.json", $(%*{
  "name": "consumer",
  "version": "0.1.0",
  "source": "src",
  "entry": "src/main.iv",
  "dependencies": newJObject(),
}))
writeFile(root / "src" / "main.iv", "use stateful.\ndisplay label.\n")

cliProject.dependency("add", "stateful", absolutePath(stateful), root)
var declared = parseJson(readFile(root / "project.json"))
doAssert declared["dependencies"]["stateful"].getStr() == "path+../stateful"
declared["dependencies"]["remote"] = %"^1.0.0"
writeFile(root / "project.json", $declared)

let remoteContent = "public constant remote is \"registry\".\n"
let remoteSource = %*{
  "format": "foo.source/v1",
  "digest": sha256Hex("src/main.iv\0" & remoteContent & "\0"),
  "files": [{"path": "src/main.iv", "content": remoteContent}],
}
let remoteEntry = %*{
  "schema": "foo.entry/v1",
  "name": "remote",
  "version": "1.0.0",
  "versions": [{"version": "1.0.0", "path": "packages/remote/1.0.0.json"}],
}
var registryFiles = initTable[string, string]()
registryFiles["indexes/index.json"] = $(%*{
  "schema": "foo.registry/v1",
  "revision": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "shards": [{"path": "indexes/index-000001.jsonl"}],
})
registryFiles["indexes/index-000001.jsonl"] = $remoteEntry & "\n"
registryFiles["registry/standard.json"] = $(%*{
  "schema": "foo.standard-catalog/v1", "revision": "empty", "count": 0,
  "entries": [], "packages": [],
})
registryFiles["packages/remote/1.0.0.json"] = $(%*{
  "schema": "foo.package/v1",
  "name": "remote",
  "version": "1.0.0",
  "repository": "https://example.invalid/remote",
  "revision": "0123456789abcdef0123456789abcdef01234567",
  "dependencies": newJArray(),
  "source": remoteSource,
})
setRegistryTransport(proc(config: Registry; path, methodName, body, token: string): RegistryResponse =
  discard config; discard methodName; discard body; discard token
  if registryFiles.hasKey(path): RegistryResponse(status: 200, body: registryFiles[path])
  else: RegistryResponse(status: 404, body: "{\"error\":\"not found\"}"))

var events: seq[string]
let installed = install(root, progress = proc(phase, name, detail: string) =
  events.add(phase & ":" & name & ":" & detail))
doAssert installed.len == 3
doAssert installed.anyIt(it.name == "stateful" and it.version == "0.4.0" and it.direct)
doAssert installed.anyIt(it.name == "helper" and it.version == "1.1.0" and not it.direct)
doAssert installed.anyIt(it.name == "remote" and it.version == "1.0.0" and it.direct)
doAssert fileExists(root / ".foo" / "packages" / "stateful" / "src" / "main.iv")
doAssert fileExists(root / ".foo" / "packages" / "helper" / "src" / "main.iv")
doAssert fileExists(root / ".foo" / "packages" / "remote" / "src" / "main.iv")
doAssert events.anyIt(it.startsWith("install:stateful@0.4.0:digest:"))

let lock = parseJson(readFile(root / "foo.lock"))
let statefulLock = lock["packages"].filterIt(it["name"].getStr() == "stateful")[0]
let helperLock = lock["packages"].filterIt(it["name"].getStr() == "helper")[0]
doAssert statefulLock["source"].getStr() == "path+../stateful"
doAssert helperLock["source"].getStr() == "path+../helper"
doAssert statefulLock["dependencies"][0].getStr() == "helper@1.1.0"
doAssert statefulLock["digest"].getStr().len == 68

let nextContent = "public constant remote is \"new registry release\".\n"
registryFiles["indexes/index-000001.jsonl"] = $(%*{
  "schema": "foo.entry/v1",
  "name": "remote",
  "version": "1.1.0",
  "versions": [
    {"version": "1.1.0", "path": "packages/remote/1.1.0.json"},
    {"version": "1.0.0", "path": "packages/remote/1.0.0.json"},
  ],
}) & "\n"
registryFiles["packages/remote/1.1.0.json"] = $(%*{
  "schema": "foo.package/v1",
  "name": "remote",
  "version": "1.1.0",
  "repository": "https://example.invalid/remote",
  "revision": "1123456789abcdef0123456789abcdef01234567",
  "dependencies": newJArray(),
  "source": {
    "format": "foo.source/v1",
    "digest": sha256Hex("src/main.iv\0" & nextContent & "\0"),
    "files": [{"path": "src/main.iv", "content": nextContent}],
  },
})
let repeated = install(root)
doAssert repeated.anyIt(it.name == "remote" and it.version == "1.0.0")
let refreshed = update(root)
doAssert refreshed.anyIt(it.name == "remote" and it.version == "1.1.0")
var unsafe = parseJson(readFile(root / "project.json"))
unsafe["dependencies"]["stateful"] = %"path+.foo/packages/stateful"
writeFile(root / "project.json", $unsafe)
var rejectedStore = false
try:
  discard install(root)
except ValueError as error:
  rejectedStore = error.msg.contains("inside .foo/packages")
doAssert rejectedStore
doAssert fileExists(root / ".foo" / "packages" / "stateful" / "src" / "main.iv")
removeDir(base)
echo "local package installation and transitive paths: ok"
