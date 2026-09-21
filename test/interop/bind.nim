import std/[os, strutils]
import "../../src/interop/bind.nim" as binding

let root = getTempDir() / "foo-interop-bind-test"
if dirExists(root): removeDir(root)
createDir(root)
let header = root / "foreign.h"
writeFile(header, "#define ANSWER 42\nint increment(int value);\n")
let options = BindOptions(cacheDir: root / "cache")
let first = binding.`bind`(header, options)
doAssert not first.cached
doAssert first.source.contains("constant ANSWER is 42.")
doAssert first.source.contains("function increment(value of type integer 32) of type integer 32")
let second = binding.`bind`(header, options)
doAssert second.cached
doAssert second.source == first.source
removeDir(root)
echo "interop bind parity: ok"
