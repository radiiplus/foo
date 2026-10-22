import std/[os, strutils]
import ../../../../src/build/compiler
import ../../../../src/backend/qbe/emitter

let root = absolutePath("test/backend/qbe/fixtures")
let source = root / "placement.iv"
let program = compiler(root, target = "x64-freestanding",
  runtime = "none").ir(source)
doAssert program.storage.len == 1
doAssert program.storage[0].alignment == 4096
doAssert program.storage[0].section == ".percpu"
let il = emit(program, target = "x64-freestanding")
doAssert "section \".percpu\" \"aw\"" in il
doAssert "data $storage.cpu_page = align 16" in il
var localRejected = false
try:
  discard compiler(root, target = "x64-freestanding",
    runtime = "none").ir(root / "placement/local.iv")
except ValueError as error:
  localRejected = "file-level dynamic" in error.msg
doAssert localRejected
echo "QBE source storage placement: ok"
