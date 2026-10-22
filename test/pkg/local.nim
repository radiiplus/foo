import std/[json, os, sequtils, strutils, tables]
import ../../src/cli/project as commands
import ../../src/pkg/[hash, registry]
import ../../src/config/project as configuration

let base = getTempDir() / "foo-local-install"
let root = base / "app"
let stateful = base / "stateful"
let helper = base / "helper"
if dirExists(base): removeDir(base)
createDir(root)
createDir(root / "src")
createDir(stateful / "src")
createDir(helper / "src")

configuration.writeProject(helper, %*{
  "name": "helper",
  "version": "1.1.0",
  "source": "src",
  "entry": "src/main.iv",
  "dependencies": newJObject(),
})
writeFile(helper / "src" / "main.iv", "public constant help is \"helper\".\n")
configuration.writeProject(stateful, %*{
  "name": "stateful",
  "version": "0.4.0",
  "source": "src",
  "entry": "src/main.iv",
  "dependencies": {"helper": "path+../helper"},
})
writeFile(stateful / "src" / "main.iv",
  "use helper.\npublic constant label is help.\n")
configuration.writeProject(root, %*{
  "name": "consumer",
  "version": "0.1.0",
  "source": "src",
  "entry": "src/main.iv",
  "dependencies": newJObject(),
})
writeFile(root / "src" / "main.iv", "use stateful.\ndisplay label.\n")

commands.dependency("add", "stateful", absolutePath(stateful), root)
var declared = configuration.readProject(root)
doAssert declared["dependencies"]["stateful"].getStr() == "path+../stateful"
declared["dependencies"]["remote"] = %"^1.0.0"
configuration.writeProject(root, declared)

let remote = "public constant remote is \"registry\".\n"
let source = %*{
  "format": "foo.source/v1",
  "digest": digest("src/main.iv\0" & remote & "\0"),
  "files": [{"path": "src/main.iv", "content": remote}],
}
let entry = %*{
  "schema": "foo.entry/v1",
  "name": "remote",
  "version": "1.0.0",
  "versions": [{"version": "1.0.0", "path": "packages/remote/1.0.0.json"}],
}
var files = initTable[string, string]()
files["indexes/index.json"] = $(%*{
  "schema": "foo.registry/v1",
  "revision": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "shards": [{"path": "indexes/index-000001.jsonl"}],
})
files["indexes/index-000001.jsonl"] = $entry & "\n"
files["registry/standard.json"] = $(%*{
  "schema": "foo.standard-catalog/v1", "revision": "empty", "count": 0,
  "entries": [], "packages": [],
})
files["packages/remote/1.0.0.json"] = $(%*{
  "schema": "foo.package/v1",
  "name": "remote",
  "version": "1.0.0",
  "repository": "https://example.invalid/remote",
  "revision": "0123456789abcdef0123456789abcdef01234567",
  "dependencies": newJArray(),
  "source": source,
})
transport(proc(config: Registry; path, methodName, body, token: string): Response =
  discard config; discard methodName; discard body; discard token
  if files.hasKey(path): Response(status: 200, body: files[path])
  else: Response(status: 404, body: "{\"error\":\"not found\"}"))

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

let lock = parseJson(readFile(root / "foo.ivl"))
let persistent = lock["packages"].filterIt(it["name"].getStr() == "stateful")[0]
let pinned = lock["packages"].filterIt(it["name"].getStr() == "helper")[0]
doAssert persistent["source"].getStr() == "path+../stateful"
doAssert pinned["source"].getStr() == "path+../helper"
doAssert persistent["dependencies"][0].getStr() == "helper@1.1.0"
doAssert persistent["digest"].getStr().len == 68

let content = "public constant remote is \"new registry release\".\n"
files["indexes/index-000001.jsonl"] = $(%*{
  "schema": "foo.entry/v1",
  "name": "remote",
  "version": "1.1.0",
  "versions": [
    {"version": "1.1.0", "path": "packages/remote/1.1.0.json"},
    {"version": "1.0.0", "path": "packages/remote/1.0.0.json"},
  ],
}) & "\n"
files["packages/remote/1.1.0.json"] = $(%*{
  "schema": "foo.package/v1",
  "name": "remote",
  "version": "1.1.0",
  "repository": "https://example.invalid/remote",
  "revision": "1123456789abcdef0123456789abcdef01234567",
  "dependencies": newJArray(),
  "source": {
    "format": "foo.source/v1",
    "digest": digest("src/main.iv\0" & content & "\0"),
    "files": [{"path": "src/main.iv", "content": content}],
  },
})
let repeated = install(root)
doAssert repeated.anyIt(it.name == "remote" and it.version == "1.0.0")
let refreshed = update(root)
doAssert refreshed.anyIt(it.name == "remote" and it.version == "1.1.0")
var unsafe = configuration.readProject(root)
unsafe["dependencies"]["stateful"] = %"path+.foo/packages/stateful"
configuration.writeProject(root, unsafe)
var store = false
try:
  discard install(root)
except ValueError as error:
  store = error.msg.contains("inside .foo/packages")
doAssert store
doAssert fileExists(root / ".foo" / "packages" / "stateful" / "src" / "main.iv")
removeDir(base)
echo "local package installation and transitive paths: ok"
