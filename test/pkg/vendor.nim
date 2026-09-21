import std/[json, os]
import ../../src/pkg/vendor

let root = getTempDir() / "foo-pkg-vendor-test"
if dirExists(root): removeDir(root)
createDir(root / "deps" / "child")
writeFile(root / "deps" / "child" / "project.json", "{\"name\":\"child\",\"version\":\"1.0.0\",\"dependencies\":{}}")
writeFile(root / "deps" / "child" / "module.iv", "start() { give nothing. }")
writeFile(root / "project.json", "{\"name\":\"app\",\"version\":\"1.0.0\",\"dependencies\":{\"child\":\"path+deps/child\"}}")
vendor(root)
doAssert fileExists(root / ".artifacts/packages/child/module.iv")
doAssert fileExists(root / "project.lock")
let lock = parseJson(readFile(root / "project.lock"))
doAssert lock["packages"].len == 1
removeDir(root)
echo "pkg vendor parity: ok"
