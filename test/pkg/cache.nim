import std/os
import ../../src/pkg/[cache, hash]

let root = getTempDir() / "foo-cache-test"
createDir(root)
let artifact = root / "output.bin"
writeFile(artifact, "first")
let receipt = newCache(artifact, "settings")
doAssert not receipt.valid
receipt.save()
doAssert receipt.valid
writeFile(artifact, "changed")
doAssert not receipt.valid
doAssert digest(artifact) == hashFile(artifact)

let toolDir = root / "tool"
doAssert tool(artifact, toolDir) == tool(artifact, toolDir)
let packageRoot = root / ".artifacts"
createDir(packageRoot / "cache" / "packages")
writeFile(packageRoot / "cache" / "packages" / "entry", "x")

removeFile(artifact)
removeFile(artifact & ".cache.json")
removeFile(toolDir / "tool.json")
removeDir(toolDir)
removeFile(packageRoot / "cache" / "packages" / "entry")
removeDir(packageRoot / "cache" / "packages")
removeDir(packageRoot / "cache")
removeDir(packageRoot)
removeDir(root)
echo "package cache parity: ok"
