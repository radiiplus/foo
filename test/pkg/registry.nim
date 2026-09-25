import std/[json, tables]
import ../../src/pkg/registry

let index = %*{
  "schema": "foo.registry/v1",
  "revision": "registry-revision",
  "shards": [{"path": "indexes/index-000001.jsonl"}],
}
let entry = %*{
  "schema": "foo.entry/v1",
  "name": "foo-http",
  "version": "1.4.2",
  "description": "HTTP networking for Foo.",
  "category": "networking",
  "tags": ["http", "websocket"],
  "exports": ["connect", "request"],
  "versions": [{"version": "1.4.2", "path": "packages/foo-http/1.4.2.json"}],
}
let package = %*{
  "schema": "foo.package/v1",
  "name": "foo-http",
  "version": "1.4.2",
  "description": "HTTP networking for Foo.",
}
let scopedEntry = %*{
  "schema": "foo.entry/v1",
  "name": "@radiiplus/foo-http",
  "version": "2.0.0",
  "description": "Scoped HTTP networking for Foo.",
  "category": "networking",
  "tags": ["http"],
  "versions": [{"version": "2.0.0", "path": "packages/@radiiplus/foo-http/2.0.0.json"}],
}
var files = initTable[string, string]()
files["indexes/index.json"] = $index
files["indexes/index-000001.jsonl"] = $entry & "\n" & $scopedEntry & "\n"
files["packages/foo-http/1.4.2.json"] = $package
setRegistryTransport(proc(config: Registry; path, methodName, body, token: string): RegistryResponse =
  discard config; discard methodName; discard body; discard token
  if files.hasKey(path): RegistryResponse(status: 200, body: files[path])
  else: RegistryResponse(status: 404, body: "{\"error\":\"not found\"}")
)

doAssert exactVersion("1.2.3")
doAssert exactVersion("1.2.3-beta.1")
doAssert not exactVersion("^1.2.3")
doAssert search(".", "websocket").len == 1
doAssert search(".", "connect").len == 1
doAssert latestVersion(".", "foo-http") == "1.4.2"
doAssert latestVersion(".", "@radiiplus/foo-http") == "2.0.0"
doAssert info(".", "foo-http")["version"].getStr() == "1.4.2"
echo "pkg registry discovery: ok"
