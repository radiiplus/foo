import std/[json, os, sequtils, strutils, tables]
import ../../src/pkg/[hash, registry]

let root = getTempDir() / "foo-registry-install"
if dirExists(root): removeDir(root)
createDir(root)

proc bundle(name, version: string): JsonNode =
  let content = "public constant package_name is \"" & name & "\".\n"
  let canonical = "src/library.iv\0" & content & "\0"
  %*{
    "format": "foo.source/v1",
    "digest": sha256Hex(canonical),
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

let appRecord = record("foo-app", "1.0.0", %*[
  {"name": "foo-core", "version": "^1.0.0", "kind": "runtime", "platforms": []},
  {"name": "foo-missing", "version": "^1.0.0", "kind": "optional", "platforms": []},
  {"name": "foo-platform", "version": "^1.0.0", "kind": "platform", "platforms": ["never"]},
])
let coreOne = record("foo-core", "1.0.0", newJArray())
let coreNext = record("foo-core", "1.2.0", newJArray())
let appEntry = entry("foo-app", "1.0.0", @["1.0.0"])
let coreEntry = entry("foo-core", "1.2.0", @["1.2.0", "1.0.0"])
var files = initTable[string, string]()
files["indexes/index.json"] = $(%*{
  "schema": "foo.registry/v1",
  "revision": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "shards": [{"path": "indexes/index-000001.jsonl"}],
})
files["indexes/index-000001.jsonl"] = $appEntry & "\n" & $coreEntry & "\n"
files["packages/foo-app/1.0.0.json"] = $appRecord
files["packages/foo-core/1.0.0.json"] = $coreOne
files["packages/foo-core/1.2.0.json"] = $coreNext
setRegistryTransport(proc(config: Registry; path, methodName, body, token: string): RegistryResponse =
  discard config; discard methodName; discard body; discard token
  if files.hasKey(path): RegistryResponse(status: 200, body: files[path])
  else: RegistryResponse(status: 404, body: "{\"error\":\"not found\"}")
)

writeFile(root / "project.json", $(%*{"name": "consumer", "version": "0.1.0", "dependencies": newJObject()}))
var installEvents: seq[string]
let installed = install(root, "foo-app", proc(phase, name, detail: string) =
  installEvents.add(phase & ":" & name & ":" & detail))
doAssert installed.len == 2
doAssert installEvents[0] == "resolve:dependencies:1 direct requirements"
doAssert installEvents.anyIt(it.startsWith("fetch:foo-app@1.0.0:"))
doAssert installEvents.anyIt(it.startsWith("install:foo-core@1.2.0:sha256:"))
doAssert installEvents[^1].startsWith("lock:foo.lock:")
doAssert installed.filterIt(it.name == "foo-core")[0].version == "1.2.0"
doAssert fileExists(root / ".foo" / "packages" / "foo-app" / "src" / "library.iv")
let lock = parseJson(readFile(root / "foo.lock"))
doAssert lock["format"].getStr() == "foo.lock"
doAssert lock["packages"].len == 2
doAssert lock["packages"][0]["digest"].getStr().len == 64
doAssert parseJson(readFile(root / "project.json"))["dependencies"]["foo-app"].getStr() == "^1.0.0"

var tampered = parseJson($lock)
tampered["packages"][0]["digest"] = %("0".repeat(64))
writeFile(root / "foo.lock", $tampered)
var rejectedDigest = false
try: discard install(root)
except ValueError as error: rejectedDigest = error.msg.contains("digest mismatch")
doAssert rejectedDigest
writeFile(root / "foo.lock", $lock)

# An unchanged manifest reproduces the exact lock even when a newer compatible release appears.
let coreNewest = record("foo-core", "1.3.0", newJArray())
files["packages/foo-core/1.3.0.json"] = $coreNewest
let expandedCore = entry("foo-core", "1.3.0", @["1.3.0", "1.2.0", "1.0.0"])
files["indexes/index-000001.jsonl"] = $appEntry & "\n" & $expandedCore & "\n"
let reproduced = install(root)
doAssert reproduced.filterIt(it.name == "foo-core")[0].version == "1.2.0"
let updated = update(root)
doAssert updated.filterIt(it.name == "foo-core")[0].version == "1.3.0"

# Editing a dependency constraint in project.json invalidates the lock and installs the requested release.
let appNext = record("foo-app", "1.1.0", %*[
  {"name": "foo-core", "version": "^1.0.0", "kind": "runtime", "platforms": []},
])
files["packages/foo-app/1.1.0.json"] = $appNext
let expandedApp = entry("foo-app", "1.1.0", @["1.1.0", "1.0.0"])
files["indexes/index-000001.jsonl"] = $expandedApp & "\n" & $expandedCore & "\n"
var changedProject = parseJson(readFile(root / "project.json"))
changedProject["dependencies"]["foo-app"] = %"1.1.0"
writeFile(root / "project.json", $changedProject)
var changedEvents: seq[string]
let changed = install(root, progress = proc(phase, name, detail: string) =
  changedEvents.add(phase & ":" & name & ":" & detail))
doAssert changed.filterIt(it.name == "foo-app")[0].version == "1.1.0"
doAssert changed.filterIt(it.name == "foo-core")[0].version == "1.3.0"
doAssert changedEvents.anyIt(it.startsWith("fetch:foo-app@1.1.0:"))
doAssert changedEvents[^1].startsWith("lock:foo.lock:")
let changedLock = parseJson(readFile(root / "foo.lock"))
doAssert changedLock["requirements"].filterIt(it["name"].getStr() == "foo-app")[0]["version"].getStr() == "1.1.0"
doAssert changedLock["packages"].filterIt(it["name"].getStr() == "foo-app")[0]["version"].getStr() == "1.1.0"

discard removePackage(root, "foo-app")
doAssert parseJson(readFile(root / "project.json"))["dependencies"].len == 0

let breaking = record("foo-breaking", "1.0.0", %*[
  {"name": "foo-core", "version": "^2.0.0", "kind": "runtime", "platforms": []},
])
let breakingEntry = entry("foo-breaking", "1.0.0", @["1.0.0"])
files["packages/foo-breaking/1.0.0.json"] = $breaking
files["indexes/index-000001.jsonl"] = $appEntry & "\n" & $breakingEntry & "\n" & $expandedCore & "\n"
var conflictProject = parseJson(readFile(root / "project.json"))
conflictProject["dependencies"] = %*{"foo-app": "^1.0.0", "foo-breaking": "^1.0.0"}
writeFile(root / "project.json", $conflictProject)
if fileExists(root / "foo.lock"): removeFile(root / "foo.lock")
var rejectedConflict = false
try: discard install(root)
except ValueError as error: rejectedConflict = error.msg.contains("Dependency conflict for foo-core")
doAssert rejectedConflict
removeDir(root)
echo "registry range resolution and lock reproduction: ok"
