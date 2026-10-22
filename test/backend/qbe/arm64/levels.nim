import std/[os, strutils]
import ../../../../src/backend/qbe/driver
import ../../../../src/build/options
import ../../../../src/ir/[kind, node, valid]

let unit = `Type`(kind: Shape.Void)
let natural = `Type`(kind: Shape.Uint, width: 64)
let counter = Value(kind: Flavor.Global, name: "counter",
  `type`: `Type`(kind: Shape.Ptr, elem: natural))

let bootTemplate = """
.text
.globl _start
_start:
movz x2, #0x4028, lsl #16
mov sp, x2
mrs x0, CurrentEL
cmp x0, #@CURRENT@
b.ne failed
adr x0, vectors
msr vbar_el@LEVEL@, x0
isb
mrs x0, cptr_el@LEVEL@
bic x0, x0, #0x400
msr cptr_el@LEVEL@, x0
isb
mov x19, #85
mov x0, #0x55
fmov d31, x0
mov x0, #0x400000
msr fpcr, x0
mov x0, #1
msr fpsr, x0
svc #0
cmp x19, #85
b.ne failed
fmov x0, d31
cmp x0, #0x55
b.ne failed
mrs x0, fpcr
mov x1, #0x400000
cmp x0, x1
b.ne failed
mrs x0, fpsr
cmp x0, #1
b.ne failed
adrp x0, storage.counter
add x0, x0, :lo12:storage.counter
ldr x0, [x0]
cmp x0, #1
b.ne failed
mov x0, #0x09000000
mov w1, #@MARKER@
strb w1, [x0]
1: wfe
b 1b
failed:
mov x0, #0x09000000
mov w1, #70
strb w1, [x0]
2: wfe
b 2b
.balign 2048
vectors:
.space 0x200
b foo.irq
"""

for level in [2, 3]:
  let boot = bootTemplate.replace("@LEVEL@", $level).
    replace("@CURRENT@", $(level * 4)).
    replace("@MARKER@", $(ord('0') + level))
  let program = Module(name: "qbe-arm64-el" & $level & "-delivery",
    requires: "machine", storage: @[
      Storage(name: "counter", value: Value(kind: Flavor.Const,
        name: "0", `type`: natural))],
    native: @[Contract(id: "bootAssembly", stage: "@asm", code: boot,
      abi: "foo:1", effects: @["unknown"])], funcs: @[
      Function(name: "irq", ret: unit,
        attributes: @["interrupt_el" & $level], blocks: @[
        Block(label: "entry", instrs: @[
          Instruction(kind: Opcode.Store, `ptr`: counter,
            val: Value(kind: Flavor.Const, name: "1", `type`: natural))],
          term: Instruction(kind: Opcode.Return))])])
  discard seal(program)
  for mode in ["dev", "release"]:
    let output = ".artifacts/qbe-arm64-el" & $level & "-delivery/" & mode
    let built = build(program, mode, output,
      Native(name: "qbe-arm64-el" & $level & "-delivery",
        target: "arm64-freestanding", runtime: "none",
        script: "test/backend/qbe/fixtures/arm.ld"))
    doAssert built.success, mode & ": " & built.error
    let source = readFile(output / "main-linux.s")
    doAssert "foo.qbe.interrupt.irq" in source
    doAssert "elr_el" & $level in source
    doAssert "spsr_el" & $level in source
    doAssert "cptr_el" & $level in source
    doAssert "eret" in source
    echo "EL" & $level & " " & mode & ": " & built.artifact
