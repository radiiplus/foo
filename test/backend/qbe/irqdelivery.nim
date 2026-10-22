import std/[os, strutils]
import ../../../src/backend/qbe/driver
import ../../../src/build/options
import ../../../src/ir/[kind, node, valid]

let unit = `Type`(kind: Shape.Void)
let natural = `Type`(kind: Shape.Uint, width: 64)
let atomic = `Type`(kind: Shape.Uint, width: 64,
  attributes: @["atomic"])
let byteType = `Type`(kind: Shape.Uint, width: 8)
let halfType = `Type`(kind: Shape.Uint, width: 16)
let atomicByte = `Type`(kind: Shape.Uint, width: 8,
  attributes: @["atomic"])
let atomicHalf = `Type`(kind: Shape.Uint, width: 16,
  attributes: @["atomic"])
let bytePointer = Value(kind: Flavor.Reg, name: "byte_pointer",
  `type`: `Type`(kind: Shape.Ptr, elem: atomicByte))
let byteInput = Value(kind: Flavor.Reg, name: "byte_input", `type`: byteType)
let byteOld = Value(kind: Flavor.Reg, name: "byte_old", `type`: byteType)
let halfPointer = Value(kind: Flavor.Reg, name: "half_pointer",
  `type`: `Type`(kind: Shape.Ptr, elem: atomicHalf))
let halfInput = Value(kind: Flavor.Reg, name: "half_input", `type`: halfType)
let halfOld = Value(kind: Flavor.Reg, name: "half_old", `type`: halfType)
let counter = Value(kind: Flavor.Global, name: "counter",
  `type`: `Type`(kind: Shape.Ptr, elem: atomic))
let previous = Value(kind: Flavor.Reg, name: "previous", `type`: natural)
let current = Value(kind: Flavor.Reg, name: "current", `type`: natural)
let assembly = """
li sp, 0x80080000
la t0, trap
csrw mtvec, t0
li a1, 85
li s0, 68
li t0, 0x6000
csrs mstatus, t0
li t0, 0x3ff0000000000000
fmv.d.x f0, t0
li t0, 0x4000000000000000
fmv.d.x f31, t0
li t0, 5
fscsr t0
li t0, 8
csrw mie, t0
li t0, 0x02000000
li t1, 1
sw t1, 0(t0)
li t0, 8
csrs mstatus, t0
li t0, 85
bne a1, t0, failed
li t0, 68
bne s0, t0, failed
fmv.x.d t0, f0
li t1, 0x3ff0000000000000
bne t0, t1, failed
fmv.x.d t0, f31
li t1, 0x4000000000000000
bne t0, t1, failed
frcsr t0
li t1, 5
bne t0, t1, failed
call read_count
li t0, 1
bne a0, t0, failed
li t0, 0x44332211
sw t0, 0(sp)
addi a0, sp, 1
li a1, 255
call byte_add
li t0, 0x22
bne a0, t0, failed
lwu t0, 0(sp)
li t1, 0x44332111
bne t0, t1, failed
addi a0, sp, 1
li a1, 0x55
call byte_swap
li t0, 0x21
bne a0, t0, failed
lwu t0, 0(sp)
li t1, 0x44335511
bne t0, t1, failed
addi a0, sp, 2
li a1, 0xabcd
call foo_qbe_atomic_store16
addi a0, sp, 2
li a1, 0x3333
call half_add
li t0, 0xabcd
bne a0, t0, failed
lwu t0, 0(sp)
li t1, 0xdf005511
bne t0, t1, failed
addi a0, sp, 2
li a1, 0x100
call foo_qbe_atomic_sub16
li t0, 0xdf00
bne a0, t0, failed
addi a0, sp, 2
call foo_qbe_atomic_load16
li t0, 0xde00
bne a0, t0, failed
addi a0, sp, 3
li a1, 0x99
call foo_qbe_atomic_swap8
li t0, 0xde
bne a0, t0, failed
lwu t0, 0(sp)
li t1, 0x99005511
bne t0, t1, failed
li t0, 0x10000000
li t1, 82
sb t1, 0(t0)
1: wfi
j 1b
failed:
li t0, 0x10000000
li t1, 70
sb t1, 0(t0)
2: wfi
j 2b
.align 2
trap:
li t0, 0x02000000
sw zero, 0(t0)
li t0, 0x10000000
li t1, 73
sb t1, 0(t0)
j foo.irq
"""
let program = Module(name: "qbe-irq-delivery", requires: "machine",
  storage: @[Storage(name: "counter", value: Value(kind: Flavor.Const,
    name: "0", `type`: atomic))],
  native: @[Contract(id: "bootAssembly", stage: "@asm", code: assembly,
    abi: "c", effects: @["unknown"])], funcs: @[
    Function(name: "boot", ret: unit, attributes: @["start", "naked"],
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Native, symbol: "bootAssembly")],
        term: Instruction(kind: Opcode.Return))]),
    Function(name: "irq", ret: unit, attributes: @["interrupt"],
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Atomic, op: "add", field: "acq_rel",
          `ptr`: counter, val: Value(kind: Flavor.Const, name: "1",
            `type`: natural), dest: previous)],
        term: Instruction(kind: Opcode.Return))]),
    Function(name: "byte_add", abi: "c", public: true,
      params: @[bytePointer, byteInput], ret: byteType,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Atomic, op: "add", field: "acq_rel",
          `ptr`: bytePointer, val: byteInput, dest: byteOld)],
        term: Instruction(kind: Opcode.Return, value: byteOld))]),
    Function(name: "byte_swap", abi: "c", public: true,
      params: @[bytePointer, byteInput], ret: byteType,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Atomic, op: "swap", field: "seq_cst",
          `ptr`: bytePointer, val: byteInput, dest: byteOld)],
        term: Instruction(kind: Opcode.Return, value: byteOld))]),
    Function(name: "half_add", abi: "c", public: true,
      params: @[halfPointer, halfInput], ret: halfType,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Atomic, op: "add", field: "acq_rel",
          `ptr`: halfPointer, val: halfInput, dest: halfOld)],
        term: Instruction(kind: Opcode.Return, value: halfOld))]),
    Function(name: "read_count", abi: "c", public: true, ret: natural,
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Atomic, op: "load", field: "acquire",
          `ptr`: counter, dest: current)],
        term: Instruction(kind: Opcode.Return, value: current))])])

discard seal(program)

for mode in ["dev", "release"]:
  let output = ".artifacts/qbe-irqdelivery/" & mode
  let built = build(program, mode, output,
    Native(name: "qbe-irq-delivery", target: "riscv64-freestanding",
      runtime: "none", script: "test/backend/qbe/fixtures/riscv.ld"))
  doAssert built.success, mode & ": " & built.error
  let ir = readFile(output / "main.ssa")
  let source = readFile(output / "main-linux.s")
  doAssert "foo_qbe_atomic_add64" in ir
  doAssert "foo_qbe_atomic_add8" in ir
  doAssert "foo_qbe_atomic_add16" in ir
  doAssert "foo.qbe.interrupt.irq" in source
  doAssert "%pcrel_hi(storage.counter)" in source
  doAssert "mret" in source
  echo mode & ": " & built.artifact
