import std/[os, strutils]
import ../../src/pkg/cache as storage
import ../../src/pkg/hash as hashing

let root = getTempDir() / "foo-cache-test"
createDir(root)
let artifact = root / "output.bin"
writeFile(artifact, "first")
let receipt = storage.cache(artifact, "settings")
doAssert not receipt.valid
receipt.save()
doAssert receipt.valid
writeFile(artifact, "changed")
doAssert not receipt.valid
doAssert storage.digest(artifact) == hashing.file(artifact)

let dir = root / "tool"
doAssert storage.tool(artifact, dir) == storage.tool(artifact, dir)
let workspace = root / ".artifacts"
createDir(workspace / "cache" / "packages")
writeFile(workspace / "cache" / "packages" / "entry", "x")

removeFile(artifact)
removeFile(artifact & ".cache.json")
removeFile(dir / "tool.json")
removeDir(dir)
removeFile(workspace / "cache" / "packages" / "entry")
removeDir(workspace / "cache" / "packages")
removeDir(workspace / "cache")
removeDir(workspace)
removeDir(root)
echo "package cache parity: ok"

block hashContracts:
  let empty = hashing.buffer("")
  doAssert empty == "1220e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  doAssert hashing.buffer("abc") == "1220ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  let directory = getTempDir() / "foo-hash-test"
  if dirExists(directory): removeDir(directory)
  createDir(directory)
  writeFile(directory / "b.txt", "two")
  writeFile(directory / "a.txt", "one")
  let first = hashing.directory(directory)
  writeFile(directory / ".ignored", "ignored")
  doAssert hashing.directory(directory) != first
  doAssert hashing.file(directory / "a.txt") == hashing.buffer("one")
  for size in [0, 1, 55, 56, 63, 64, 65, 65535, 65536, 65537]:
    let content = repeat("a", size)
    writeFile(directory / "stream.bin", content)
    doAssert hashing.checksum(directory / "stream.bin") == hashing.digest(content)
  removeFile(directory / "stream.bin")
  let path = hashing.directory(directory)
  for excluded in [".git", "node_modules", ".artifacts"]:
    createDir(directory / excluded)
    writeFile(directory / excluded / "ignored.txt", "ignored")
  doAssert hashing.directory(directory) == path
  createDir(directory / "dist")
  writeFile(directory / "dist" / "generated.bin", "generated")
  doAssert hashing.directory(directory, @[directory / "dist"]) == path
  removeFile(directory / "dist" / "generated.bin")
  removeDir(directory / "dist")
  for excluded in [".git", "node_modules", ".artifacts"]:
    removeFile(directory / excluded / "ignored.txt")
    removeDir(directory / excluded)
  removeFile(directory / "b.txt")
  removeFile(directory / "a.txt")
  removeFile(directory / ".ignored")
  removeDir(directory)
echo "package hash parity: ok"
