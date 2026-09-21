import std/[base64, json, os]
import ../../src/pkg/hash
import ../../src/pkg/registry

doAssert canonical(%*{"b": 2, "a": 1}) == "{\"a\":1,\"b\":2}"
let root = getTempDir() / "foo-registry-test"
let mirrorRoot = getTempDir() / "foo-registry-mirror-test"
if dirExists(root): removeDir(root)
if dirExists(mirrorRoot): removeDir(mirrorRoot)
createDir(root / ".artifacts" / "registry" / "objects")
createDir(root / ".artifacts" / "packages" / "acme" / "math")
writeFile(root / "project.json", "{\"registry\":{\"url\":\"https://registry.example\",\"keys\":{\"acme\":{\"test-key\":\"public\"}}}}")
setRegistryCrypto(RegistryCrypto(verify: proc(publicKey, message, signature: string): bool =
  publicKey == "public" and message.len > 0 and signature == "test"))
writeFile(root / ".artifacts" / "packages" / "acme" / "math" / "project.json", "{\"name\":\"acme/math\",\"version\":\"1.0.0\",\"dependencies\":{}}")
writeFile(root / ".artifacts" / "packages" / "acme" / "math" / "main.iv", "start() {}")
let archive = canonical(%*{"schema": 1, "files": [{"path": "project.json", "data": encode("{\"name\":\"acme/math\",\"version\":\"1.0.0\",\"dependencies\":{}}")}, {"path": "main.iv", "data": encode("start() {}")}]})
let digest = sha256Hex(archive)
writeFile(root / ".artifacts" / "registry" / "objects" / (digest & ".json"), archive)
let lock = %*{"schema": 1, "packages": [{"name": "acme/math", "version": "1.0.0", "digest": digest, "signed": {"release": {"schema": 1, "name": "acme/math", "version": "1.0.0", "digest": digest, "key": "test-key", "dependencies": {}}, "signature": "test"}}]}
writeFile(root / ".artifacts" / "registry" / "lock.json", $lock)
doAssert audit(root) == 1
createDir(mirrorRoot)
doAssert mirror(root, mirrorRoot) == 1
doAssert fileExists(mirrorRoot / "objects" / (digest & ".json"))
removeDir(root)
removeDir(mirrorRoot)
echo "pkg registry parity: ok"
