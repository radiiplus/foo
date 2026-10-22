import std/[os, strutils]
import ../../../../src/backend/qbe/driver
import ../../../../src/build/options
import ../../../../src/ir/[kind, node, valid]
import ../../../../src/ir/parse as parseIr
import ../../../../src/ir/print as printIr

let boolean = `Type`(kind: Shape.Bool)
let u32 = `Type`(kind: Shape.Uint, width: 32)
let u64 = `Type`(kind: Shape.Uint, width: 64)
let volatileI8 = `Type`(kind: Shape.Int, width: 8, volatile: true)
let atomicU32 = `Type`(kind: Shape.Uint, width: 32,
  attributes: @["atomic"])
let counter = Value(kind: Flavor.Global, name: "counter",
  `type`: `Type`(kind: Shape.Ptr, elem: atomicU32))
let mmio = Value(kind: Flavor.Global, name: "mmio",
  `type`: `Type`(kind: Shape.Ptr, elem: volatileI8))
let cpuPage = Value(kind: Flavor.Global, name: "cpu_page",
  `type`: `Type`(kind: Shape.Ptr, elem: u64))

proc reg(name: string; t: `Type`): Value =
  Value(kind: Flavor.Reg, name: name, `type`: t)

proc number(value: string; t: `Type`): Value =
  Value(kind: Flavor.Const, name: value, `type`: t)

let previous = reg("previous", u32)
let observed = reg("observed", u32)
let atomOk = reg("atom_ok", boolean)
let atomicProbe = Function(name: "probe_atomic", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Atomic, op: "store", field: "seq_cst",
      `ptr`: counter, val: number("7", u32)),
    Instruction(kind: Opcode.Atomic, op: "add", field: "acq_rel",
      `ptr`: counter, val: number("3", u32), dest: previous),
    Instruction(kind: Opcode.Atomic, op: "load", field: "acquire",
      `ptr`: counter, dest: observed),
    Instruction(kind: Opcode.Compare, op: "equals", dest: atomOk,
      val: observed, val2: number("10", u32))],
    term: Instruction(kind: Opcode.Return, value: atomOk))])

proc atomicWidth(width: int): Function =
  let t = `Type`(kind: Shape.Uint, width: width)
  let atomic = `Type`(kind: Shape.Uint, width: width,
    attributes: @["atomic"])
  let pointer = Value(kind: Flavor.Global, name: "counter" & $width,
    `type`: `Type`(kind: Shape.Ptr, elem: atomic))
  let priorAdd = reg("prior_add", t)
  let priorSub = reg("prior_sub", t)
  let priorSwap = reg("prior_swap", t)
  let after = reg("after", t)
  let valueOk = reg("value_ok", boolean)
  Function(name: "probe_atomic" & $width, public: true, abi: "c",
    ret: boolean, blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Atomic, op: "store", field: "release",
        `ptr`: pointer, val: number("7", t)),
      Instruction(kind: Opcode.Atomic, op: "add", field: "acq_rel",
        `ptr`: pointer, val: number("3", t), dest: priorAdd),
      Instruction(kind: Opcode.Atomic, op: "sub", field: "seq_cst",
        `ptr`: pointer, val: number("2", t), dest: priorSub),
      Instruction(kind: Opcode.Atomic, op: "swap", field: "seq_cst",
        `ptr`: pointer, val: number("5", t), dest: priorSwap),
      Instruction(kind: Opcode.Atomic, op: "load", field: "acquire",
        `ptr`: pointer, dest: after),
      Instruction(kind: Opcode.Compare, op: "equals", dest: valueOk,
        val: after, val2: number("5", t))],
      term: Instruction(kind: Opcode.Return, value: valueOk))])

let pageValue = reg("page_value", u64)
let pageOk = reg("page_ok", boolean)
let pageProbe = Function(name: "probe_page", public: true, abi: "c",
  ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Load, `ptr`: cpuPage, dest: pageValue),
    Instruction(kind: Opcode.Compare, op: "equals", dest: pageOk,
      val: pageValue, val2: number("0", u64))],
    term: Instruction(kind: Opcode.Return, value: pageOk))])

let seen = reg("seen", volatileI8)
let volatileOk = reg("volatile_ok", boolean)
let volatileProbe = Function(name: "probe_volatile", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Store, `ptr`: mmio,
      val: number("-7", volatileI8)),
    Instruction(kind: Opcode.Load, `ptr`: mmio, dest: seen),
    Instruction(kind: Opcode.Compare, op: "equals", dest: volatileOk,
      val: seen, val2: number("-7", volatileI8))],
    term: Instruction(kind: Opcode.Return, value: volatileOk))])

let x64Boot = """
.text
.globl _start
_start:
andq $-16, %rsp
call probe_atomic
cmpl $1, %eax
jne failed
call probe_atomic8
cmpl $1, %eax
jne failed
call probe_atomic16
cmpl $1, %eax
jne failed
call probe_atomic64
cmpl $1, %eax
jne failed
call probe_page
cmpl $1, %eax
jne failed
call probe_volatile
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
bl probe_atomic
cmp w0, #1
b.ne failed
bl probe_atomic8
cmp w0, #1
b.ne failed
bl probe_atomic16
cmp w0, #1
b.ne failed
bl probe_atomic64
cmp w0, #1
b.ne failed
bl probe_page
cmp w0, #1
b.ne failed
bl probe_volatile
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
call probe_atomic
li t0, 1
bne a0, t0, failed
call probe_atomic8
li t0, 1
bne a0, t0, failed
call probe_atomic16
li t0, 1
bne a0, t0, failed
call probe_atomic64
li t0, 1
bne a0, t0, failed
call probe_page
li t0, 1
bne a0, t0, failed
call probe_volatile
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
  let program = Module(name: "qbe-freestanding-memory", requires: "machine",
    funcs: @[atomicProbe, atomicWidth(8), atomicWidth(16),
      atomicWidth(64), pageProbe, volatileProbe], storage: @[
      Storage(name: "counter", value: number("0", atomicU32)),
      Storage(name: "counter8", value: number("0", `Type`(kind: Shape.Uint,
        width: 8, attributes: @["atomic"]))),
      Storage(name: "counter16", value: number("0", `Type`(kind: Shape.Uint,
        width: 16, attributes: @["atomic"]))),
      Storage(name: "counter64", value: number("0", `Type`(kind: Shape.Uint,
        width: 64, attributes: @["atomic"]))),
      Storage(name: "mmio", value: number("0", volatileI8)),
      Storage(name: "external_page", public: true, alignment: 4096,
        section: ".percpu", value: number("0", u64)),
      Storage(name: "cpu_page", alignment: 4096, section: ".percpu",
        value: number("0", u64))], native: @[
      Contract(id: "startup", stage: "@asm", code: assembly,
        abi: "foo:1", effects: @["unknown"])])
  discard seal(program)
  let restored = parseIr.decode(printIr.encode(program))
  doAssert restored.storage.len == program.storage.len
  var preservedPage = false
  for item in restored.storage:
    if item.name == "cpu_page":
      doAssert item.alignment == 4096 and item.section == ".percpu"
      preservedPage = true
  doAssert preservedPage
  for mode in ["dev", "release"]:
    let output = ".artifacts/qbe-freestanding-memory/" & target & "-" & mode
    let built = build(program, mode, output,
      Native(name: "qbe-freestanding-memory", target: target,
        runtime: "none", script: script))
    doAssert built.success, target & " " & mode & ": " & built.error
    let il = readFile(output / "main.ssa")
    doAssert "section \".percpu\"" in il
    doAssert "$storage.external_page" in il
    doAssert "data $storage.cpu_page = align 16" in il
    doAssert ".balign 4096" in readFile(output / "main-linux.s")
    doAssert "$foo_qbe_atomic_add32" in il
    doAssert "$foo_qbe_volatile_load8" in il
    echo target & " " & mode & ": " & built.artifact
