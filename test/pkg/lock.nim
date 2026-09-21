import std/os
import ../../src/pkg/lock

let root = getTempDir() / "foo-pkg-lock-test"
if dirExists(root): removeDir(root)
createDir(root)
let path = root / "project.lock"
let original = Lockfile(version: 1, packages: @[LockedPackage(name: "std/testing", source: "registry+std/testing@1.0.0", hash: "sha256:abc")])
writeLock(path, original)
let loaded = readLock(path)
doAssert loaded != nil
doAssert loaded.version == 1
doAssert loaded.packages[0].name == "std/testing"
writeFile(path, "broken")
doAssert readLock(path) == nil
removeDir(root)
echo "pkg lock parity: ok"
