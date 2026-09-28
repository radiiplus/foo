import std/[os, strutils]
import ../../src/pkg/hash

let empty = hashBuffer("")
doAssert empty == "1220e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
doAssert hashBuffer("abc") == "1220ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

let directory = getTempDir() / "foo-hash-test"
if dirExists(directory): removeDir(directory)
createDir(directory)
writeFile(directory / "b.txt", "two")
writeFile(directory / "a.txt", "one")
let first = hashDirectory(directory)
writeFile(directory / ".ignored", "ignored")
doAssert hashDirectory(directory) != first
doAssert hashFile(directory / "a.txt") == hashBuffer("one")
let withVisibleFile = hashDirectory(directory)
for excluded in [".git", "node_modules", ".artifacts"]:
  createDir(directory / excluded)
  writeFile(directory / excluded / "ignored.txt", "ignored")
doAssert hashDirectory(directory) == withVisibleFile
for excluded in [".git", "node_modules", ".artifacts"]:
  removeFile(directory / excluded / "ignored.txt")
  removeDir(directory / excluded)
removeFile(directory / "b.txt"); removeFile(directory / "a.txt"); removeFile(directory / ".ignored"); removeDir(directory)

echo "package hash parity: ok"
