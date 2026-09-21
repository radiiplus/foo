import std/os
import ../../src/build/cache

let root = getTempDir() / "foo-build-cache-test"
createDir(root)
let output = root / "artifact"
writeFile(output, "compiled")
let receipt = newCache(output, "compiler-settings")
doAssert not receipt.valid
receipt.save()
doAssert receipt.valid
writeFile(output, "changed")
doAssert not receipt.valid
doAssert digest(output).len == 68
removeFile(output)
removeFile(output & ".cache.json")
removeDir(root)
echo "build cache parity: ok"
