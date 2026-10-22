import std/os
import ../../src/pkg/lock
import std/json
import ../../src/pkg/vendor as packageVendor
import ../../src/config/project as configuration

let root = getTempDir() / "foo-pkg-lock-test"
if dirExists(root): removeDir(root)
createDir(root)
let path = root / "project.ivl"
let original = Lockfile(version: 1, packages: @[Locked(name: "lib/testing", source: "registry+lib/testing@1.0.0", hash: "sha256:abc")])
write(path, original)
let loaded = read(path)
doAssert loaded != nil
doAssert loaded.version == 1
doAssert loaded.packages[0].name == "lib/testing"
writeFile(path, "broken")
doAssert read(path) == nil
removeDir(root)
echo "pkg lock parity: ok"

block vendoredLock:
  let root = getTempDir() / "foo-pkg-vendor-test"
  if dirExists(root): removeDir(root)
  createDir(root / "deps" / "child")
  configuration.writeProject(root / "deps" / "child", %*{
    "name": "child", "version": "1.0.0"})
  writeFile(root / "deps" / "child" / "module.iv", "start { give nothing. }")
  configuration.writeProject(root, %*{"name": "app", "version": "1.0.0",
    "dependencies": {"child": "path+deps/child"}})
  packageVendor.vendor(root)
  doAssert fileExists(root / ".artifacts/packages/child/module.iv")
  doAssert fileExists(root / "project.ivl")
  let lock = parseJson(readFile(root / "project.ivl"))
  doAssert lock["packages"].len == 1
  removeDir(root)
echo "pkg vendor parity: ok"
