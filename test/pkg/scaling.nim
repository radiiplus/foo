import std/[json, os, sequtils, strutils, tables]
import ../../src/pkg/[hash, registry]
import ../../src/config/project as configuration

let root = getTempDir() / "foo-registry-install"
if dirExists(root): removeDir(root)
createDir(root)

proc bundle(name, version: string): JsonNode =
  let content = "public constant package_name is \"" & name & "\".\n"
  let canonical = "src/library.iv\0" & content & "\0"
  %*{
    "format": "foo.source/v1",
    "digest": digest(canonical),
    "files": [{"path": "src/library.iv", "content": content}],
  }

proc record(name, version: string; dependencies: JsonNode): JsonNode =
  %*{
    "schema": "foo.package/v1",
    "name": name,
    "version": version,
    "repository": "https://github.com/example/" & name,
    "revision": "0123456789abcdef0123456789abcdef01234567",
    "dependencies": dependencies,
    "source": bundle(name, version),
  }

proc entry(name, latest: string; versions: seq[string]): JsonNode =
  var releases = newJArray()
  for version in versions:
    releases.add(%*{
      "version": version,
      "updated": "2026-09-25",
      "deprecated": "",
      "path": "packages/" & name & "/" & version & ".json",
    })
  %*{
    "schema": "foo.entry/v1",
    "name": name,
    "version": latest,
    "description": name,
    "category": "test",
    "tags": [],
    "versions": releases,
  }

let application = record("foo-app", "1.0.0", %*[
  {"name": "foo-core", "version": "^1.0.0", "kind": "runtime", "platforms": []},
  {"name": "foo-missing", "version": "^1.0.0", "kind": "optional", "platforms": []},
  {"name": "foo-platform", "version": "^1.0.0", "kind": "platform", "platforms": ["never"]},
])
let one = record("foo-core", "1.0.0", newJArray())
let following = record("foo-core", "1.2.0", newJArray())
let app = entry("foo-app", "1.0.0", @["1.0.0"])
let core = entry("foo-core", "1.2.0", @["1.2.0", "1.0.0"])
var files = initTable[string, string]()
files["indexes/index.json"] = $(%*{
  "schema": "foo.registry/v1",
  "revision": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "shards": [{"path": "indexes/index-000001.jsonl"}],
})
files["indexes/index-000001.jsonl"] = $app & "\n" & $core & "\n"
files["registry/standard.json"] = $(%*{
  "schema": "foo.standard-catalog/v1", "revision": "empty", "count": 0,
  "entries": [], "packages": [],
})
files["packages/foo-app/1.0.0.json"] = $application
files["packages/foo-core/1.0.0.json"] = $one
files["packages/foo-core/1.2.0.json"] = $following
transport(proc(config: Registry; path, methodName, body, token: string): Response =
  discard config; discard methodName; discard body; discard token
  if files.hasKey(path): Response(status: 200, body: files[path])
  else: Response(status: 404, body: "{\"error\":\"not found\"}")
)

configuration.writeProject(root, %*{"name": "consumer", "version": "0.1.0"})
var installations: seq[string]
let installed = install(root, "foo-app", proc(phase, name, detail: string) =
  installations.add(phase & ":" & name & ":" & detail))
doAssert installed.len == 2
doAssert installations[0] == "resolve:dependencies:1 direct requirements"
doAssert installations.anyIt(it.startsWith("fetch:foo-app@1.0.0:"))
doAssert installations.anyIt(it.startsWith("install:foo-core@1.2.0:sha256:"))
doAssert installations[^1].startsWith("lock:foo.ivl:")
doAssert installed.filterIt(it.name == "foo-core")[0].version == "1.2.0"
doAssert fileExists(root / ".foo" / "packages" / "foo-app" / "src" / "library.iv")
let lock = parseJson(readFile(root / "foo.ivl"))
doAssert lock["format"].getStr() == "foo.ivl"
doAssert lock["packages"].len == 2
doAssert lock["packages"][0]["digest"].getStr().len == 64
doAssert configuration.readProject(root)["dependencies"]["foo-app"].getStr() == "^1.0.0"

var tampered = parseJson($lock)
tampered["packages"][0]["digest"] = %("0".repeat(64))
writeFile(root / "foo.ivl", $tampered)
var fingerprint = false
try: discard install(root)
except ValueError as error: fingerprint = error.msg.contains("digest mismatch")
doAssert fingerprint
writeFile(root / "foo.ivl", $lock)

# An unchanged manifest reproduces the exact lock even when a newer compatible release appears.
let newest = record("foo-core", "1.3.0", newJArray())
files["packages/foo-core/1.3.0.json"] = $newest
let extended = entry("foo-core", "1.3.0", @["1.3.0", "1.2.0", "1.0.0"])
files["indexes/index-000001.jsonl"] = $app & "\n" & $extended & "\n"
let reproduced = install(root)
doAssert reproduced.filterIt(it.name == "foo-core")[0].version == "1.2.0"
let updated = update(root)
doAssert updated.filterIt(it.name == "foo-core")[0].version == "1.3.0"

# Editing a dependency constraint in project.ivc invalidates the lock and installs the requested release.
let next = record("foo-app", "1.1.0", %*[
  {"name": "foo-core", "version": "^1.0.0", "kind": "runtime", "platforms": []},
])
files["packages/foo-app/1.1.0.json"] = $next
let expanded = entry("foo-app", "1.1.0", @["1.1.0", "1.0.0"])
files["indexes/index-000001.jsonl"] = $expanded & "\n" & $extended & "\n"
var project = configuration.readProject(root)
project["dependencies"]["foo-app"] = %"1.1.0"
configuration.writeProject(root, project)
var events: seq[string]
let changed = install(root, progress = proc(phase, name, detail: string) =
  events.add(phase & ":" & name & ":" & detail))
doAssert changed.filterIt(it.name == "foo-app")[0].version == "1.1.0"
doAssert changed.filterIt(it.name == "foo-core")[0].version == "1.3.0"
doAssert events.anyIt(it.startsWith("fetch:foo-app@1.1.0:"))
doAssert events[^1].startsWith("lock:foo.ivl:")
let mutation = parseJson(readFile(root / "foo.ivl"))
doAssert mutation["requirements"].filterIt(it["name"].getStr() == "foo-app")[0]["version"].getStr() == "1.1.0"
doAssert mutation["packages"].filterIt(it["name"].getStr() == "foo-app")[0]["version"].getStr() == "1.1.0"

discard remove(root, "foo-app")
doAssert configuration.readProject(root)["dependencies"].len == 0

let breaking = record("foo-breaking", "1.0.0", %*[
  {"name": "foo-core", "version": "^2.0.0", "kind": "runtime", "platforms": []},
])
let incompatibility = entry("foo-breaking", "1.0.0", @["1.0.0"])
files["packages/foo-breaking/1.0.0.json"] = $breaking
files["indexes/index-000001.jsonl"] = $app & "\n" & $incompatibility & "\n" & $extended & "\n"
var conflict = configuration.readProject(root)
conflict["dependencies"] = %*{"foo-app": "^1.0.0", "foo-breaking": "^1.0.0"}
configuration.writeProject(root, conflict)
if fileExists(root / "foo.ivl"): removeFile(root / "foo.ivl")
var rejected = false
try: discard install(root)
except ValueError as error: rejected = error.msg.contains("Dependency conflict for foo-core")
doAssert rejected
removeDir(root)
echo "registry range resolution and lock reproduction: ok"
