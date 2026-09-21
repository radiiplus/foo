import std/[json, os, tables]
import ../../src/pkg/[hash, registry]

let publisher = getTempDir() / "foo-registry-publisher"
let consumer = getTempDir() / "foo-registry-consumer"
if dirExists(publisher): removeDir(publisher)
if dirExists(consumer): removeDir(consumer)
createDir(publisher / "src")
createDir(consumer)
let trust = "{\"acme\":{\"key1\":\"secret\"}}"
writeFile(publisher / "project.json", "{\"name\":\"acme/demo\",\"version\":\"1.2.3\",\"dependencies\":{},\"registry\":{\"url\":\"http://localhost:9876\",\"keys\":" & trust & "},\"publish\":{\"files\":[\"src/**/*.iv\"]}}")
writeFile(publisher / "src" / "lib.iv", "constant answer is 42.\n")

var objects = initTable[string, string]()
setRegistryTransport(proc(config: Registry; path, methodName, body, token: string): RegistryResponse =
  discard config; discard token
  if methodName == "PUT":
    if objects.hasKey(path): return RegistryResponse(status: 412)
    objects[path] = body
    return RegistryResponse(status: 201)
  if objects.hasKey(path): RegistryResponse(status: 200, body: objects[path])
  else: RegistryResponse(status: 404)
)
setRegistryCrypto(RegistryCrypto(
  keyId: proc(privatePath: string): string = "key1",
  sign: proc(privatePath, message: string): string = sha256Hex(privatePath & message),
  verify: proc(publicKey, message, signature: string): bool = signature == sha256Hex(publicKey & message)
))

doAssert publish(publisher, "secret") == "acme/demo@1.2.3"
writeFile(consumer / "project.json", "{\"name\":\"consumer/app\",\"version\":\"0.1.0\",\"dependencies\":{\"acme/demo\":\"registry+acme/demo@1.2.3\"},\"registry\":{\"url\":\"http://localhost:9876\",\"keys\":" & trust & "}}")
let installed = install(consumer)
doAssert installed.len == 1
doAssert readFile(consumer / ".artifacts" / "packages" / "acme" / "demo" / "src" / "lib.iv") == "constant answer is 42.\n"
doAssert audit(consumer) == 1
echo "pkg registry roundtrip: ok"
