import std/[os, strutils]
import ../../../../src/backend/qbe/driver
import ../../../../src/build/options
import ../../../../src/ir/[kind, node, valid]

let boolean = `Type`(kind: Shape.Bool)
let u3 = `Type`(kind: Shape.Uint, width: 3)
let u64 = `Type`(kind: Shape.Uint, width: 64)
let u128 = `Type`(kind: Shape.Uint, width: 128)
let i65 = `Type`(kind: Shape.Int, width: 65)

proc constant(t: `Type`; number: string): Value =
  Value(kind: Flavor.Const, `type`: t, name: number)

proc arithmetic(name: string; t: `Type`; op: Opcode;
    left, right, expected: string): Function =
  let value = Value(kind: Flavor.Reg, name: "value", `type`: t)
  let matched = Value(kind: Flavor.Reg, name: "matched", `type`: boolean)
  Function(name: name, public: true, abi: "c", ret: boolean,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: op, dest: value,
        val: constant(t, left), val2: constant(t, right)),
      Instruction(kind: Opcode.Compare, op: "equals", dest: matched,
        val: value, val2: constant(t, expected))],
      term: Instruction(kind: Opcode.Return, value: matched))])

let probes = @[
  arithmetic("probe_narrow", u3, Opcode.Add, "2", "3", "5"),
  arithmetic("probe_add", u128, Opcode.Add,
    "18446744073709551615", "1", "18446744073709551616"),
  arithmetic("probe_mul", u128, Opcode.Mul,
    "18446744073709551616", "3", "55340232221128654848"),
  arithmetic("probe_div", u128, Opcode.Div,
    "18446744073709551616", "2", "9223372036854775808"),
  arithmetic("probe_signed", i65, Opcode.Add,
    "-18446744073709551616", "1", "-18446744073709551615")]

let bitValue = Value(kind: Flavor.Reg, name: "bit_value", `type`: u128)
let bitMatched = Value(kind: Flavor.Reg, name: "bit_matched", `type`: boolean)
let bitProbe = Function(name: "probe_bit", public: true, abi: "c",
  ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Bit, op: "set", dest: bitValue,
      val: constant(u128, "18446744073709551616"),
      val2: constant(u64, "1")),
    Instruction(kind: Opcode.Compare, op: "equals", dest: bitMatched,
      val: bitValue, val2: constant(u128, "18446744073709551618"))],
    term: Instruction(kind: Opcode.Return, value: bitMatched))])

let x64Boot = """
.text
.globl _start
_start:
andq $-16, %rsp
call probe_narrow
cmpl $1, %eax
jne failed
call probe_add
cmpl $1, %eax
jne failed
call probe_mul
cmpl $1, %eax
jne failed
call probe_div
cmpl $1, %eax
jne failed
call probe_signed
cmpl $1, %eax
jne failed
call probe_bit
cmpl $1, %eax
jne failed
movl $42, %edi
jmp exit
failed:
movl $1, %edi
exit:
movl $60, %eax
syscall
"""

let armBoot = """
.text
.globl _start
_start:
movz x2, #0x4028, lsl #16
mov sp, x2
bl probe_narrow
cmp w0, #1
b.ne failed
bl probe_add
cmp w0, #1
b.ne failed
bl probe_mul
cmp w0, #1
b.ne failed
bl probe_div
cmp w0, #1
b.ne failed
bl probe_signed
cmp w0, #1
b.ne failed
bl probe_bit
cmp w0, #1
b.ne failed
mov w1, #87
b output
failed:
mov w1, #70
output:
mov x0, #0x09000000
strb w1, [x0]
1: wfe
b 1b
"""

let rvBoot = """
.text
.globl _start
_start:
li sp, 0x80080000
call probe_narrow
li t0, 1
bne a0, t0, failed
call probe_add
li t0, 1
bne a0, t0, failed
call probe_mul
li t0, 1
bne a0, t0, failed
call probe_div
li t0, 1
bne a0, t0, failed
call probe_signed
li t0, 1
bne a0, t0, failed
call probe_bit
li t0, 1
bne a0, t0, failed
li t1, 87
j output
failed:
li t1, 70
output:
li t0, 0x10000000
sb t1, 0(t0)
1: wfi
j 1b
"""

for (target, assembly, script) in [
    ("x64-freestanding", x64Boot, ""),
    ("arm64-freestanding", armBoot, "test/backend/qbe/fixtures/arm.ld"),
    ("riscv64-freestanding", rvBoot, "test/backend/qbe/fixtures/riscv.ld")]:
  let program = Module(name: "qbe-freestanding-integers", requires: "machine",
    funcs: probes & @[bitProbe], native: @[
      Contract(id: "startup", stage: "@asm", code: assembly,
        abi: "foo:1", effects: @["unknown"])])
  discard seal(program)
  for mode in ["dev", "release"]:
    let output = ".artifacts/qbe-freestanding-integers/" & target & "-" & mode
    let built = build(program, mode, output,
      Native(name: "qbe-freestanding-integers", target: target,
        runtime: "none", script: script))
    doAssert built.success, target & " " & mode & ": " & built.error
    doAssert "foo_qbe_integer128" in readFile(output / "main.ssa")
    echo target & " " & mode & ": " & built.artifact
