import std/os
import ../../src/build/compiler
import ../../src/ir/valid

let root = getTempDir() / "foo-build-compiler-test"
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "project.json", "{\"name\":\"compiler-test\",\"requires\":\"system\"}")
let file = root / "main.iv"
writeFile(file, "start() { give nothing. }")
let c = newCompiler(root)
doAssert not c.check(file).cached
doAssert c.check(file).cached
let lowered = c.ir(file)
doAssert lowered.funcs.len == 1
doAssert validate(lowered).len == 0
doAssert lowered.unitPackage == "compiler-test"
doAssert lowered.unitPath == "main.iv"
doAssert lowered.requires == "system"
writeFile(file, "start() { give. }")
doAssert not c.check(file).cached
removeDir(root)
echo "build compiler parity: ok"
