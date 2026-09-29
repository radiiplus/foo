import std/os
import ../../src/build/compiler
import ../../src/ir/[kind, valid]

let root = getTempDir() / "foo-build-compiler-test"
if dirExists(root): removeDir(root)
createDir(root)
writeFile(root / "project.json", "{\"name\":\"compiler-test\",\"requires\":\"system\"}")
let file = root / "main.iv"
writeFile(file, "start { give nothing. }")
let c = newCompiler(root)
doAssert not c.check(file).cached
doAssert c.check(file).cached
let lowered = c.ir(file)
doAssert lowered.funcs.len == 1
doAssert validate(lowered).len == 0
doAssert lowered.unitPackage == "compiler-test"
doAssert lowered.unitPath == "main.iv"
doAssert lowered.requires == "system"
writeFile(file, "start { give. }")
doAssert not c.check(file).cached
writeFile(file, """
use time as clock.
constant delay is clock.millis(0).
clock.wait(delay) try.
""")
let script = c.ir(file)
var foundFailableMain = false
for function in script.funcs:
  if function.name == "main":
    foundFailableMain = function.ret.kind == TypeKind.Failable
doAssert foundFailableMain
doAssert validate(script).len == 0
removeDir(root)
echo "build compiler parity: ok"
