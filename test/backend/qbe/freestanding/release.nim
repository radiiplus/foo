import std/[json, os, strutils]
import ../../../../src/backend/qbe/driver
import ../../../../src/build/options
import ../../../../src/ir/[kind, node]

let i32 = `Type`(kind: Shape.Int, width: 32)
let answer = Value(kind: Flavor.Const, name: "42", `type`: i32)
let probe = Function(name: "probe", public: true, abi: "c", ret: i32,
  blocks: @[Block(label: "entry", instrs: @[],
    term: Instruction(kind: Opcode.Return, value: answer))])

let targets = [
  ("x64-freestanding", """.text
.globl _start
_start:
  call probe
  mov %eax, %edi
  mov $60, %eax
  syscall
""", ""),
  ("arm64-freestanding", """.text
.globl _start
_start:
  movz x2, #0x4028, lsl #16
  mov sp, x2
  bl probe
  mov x1, #0x09000000
  strb w0, [x1]
1: wfe
  b 1b
""", "test/backend/qbe/fixtures/arm.ld"),
  ("riscv64-freestanding", """.text
.globl _start
_start:
  li sp, 0x80080000
  call probe
  li t0, 0x10000000
  sb a0, 0(t0)
1: wfi
  j 1b
""", "test/backend/qbe/fixtures/riscv.ld")
]

for (target, startup, script) in targets:
  let program = Module(funcs: @[probe], native: @[
    Contract(id: "startup", stage: "@asm", code: startup,
      abi: "foo:1", effects: @["unknown"])])
  let settings = Native(name: "probe", kind: "exe", target: target,
    runtime: "none", script: script)
  let output = ".artifacts/qbe-freestanding-release/" & target
  let released = build(program, "release", output, settings)
  doAssert released.success, target & ": " & released.error
  doAssert fileExists(released.artifact)
  let metadata = parseFile(released.artifact & ".qbe.json")
  doAssert metadata["mode"].getStr() == "release"
  doAssert metadata["linkPolicy"].getStr() ==
    (if metadata["linker"]["path"].getStr().lastPathPart.startsWith("qbe-ld"):
      "bundled-bfd-no-undefined-gc-sections-entry-page4k-v1"
     else: "lld-no-undefined-gc-sections-entry-page4k-v2")
  doAssert metadata["linker"]["sha256"].getStr().len == 64
  let repeat = build(program, "release", output, settings)
  doAssert repeat.success and repeat.cached, target & ": " & repeat.error
  if target == "x64-freestanding":
    let developed = build(program, "dev", output & "-dev", settings)
    doAssert developed.success, developed.error
    doAssert readFile(developed.artifact) == readFile(released.artifact)
  echo target & ": " & released.artifact

let missingEntry = Module(funcs: @[probe])
let failed = build(missingEntry, "release",
  ".artifacts/qbe-freestanding-release/missing-entry",
  Native(name: "probe", kind: "exe", target: "x64-freestanding",
    runtime: "none"))
doAssert not failed.success and failed.error.contains("_start"), failed.error
