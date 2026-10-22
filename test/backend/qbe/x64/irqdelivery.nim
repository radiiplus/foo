import std/[os, strutils]
import ../../../../src/backend/qbe/driver
import ../../../../src/build/options
import ../../../../src/ir/[kind, node, valid]

let unit = `Type`(kind: Shape.Void)
let natural = `Type`(kind: Shape.Uint, width: 64)
let counter = Value(kind: Flavor.Global, name: "counter",
  `type`: `Type`(kind: Shape.Ptr, elem: natural))
let errorCode = Value(kind: Flavor.Reg, name: "error_code", `type`: natural)
let faultCode = Value(kind: Flavor.Global, name: "fault_code",
  `type`: `Type`(kind: Shape.Ptr, elem: natural))
let faultCount = Value(kind: Flavor.Global, name: "fault_count",
  `type`: `Type`(kind: Shape.Ptr, elem: natural))
let integer = `Type`(kind: Shape.Int, width: 32)
let boolean = `Type`(kind: Shape.Bool)
let failable = `Type`(kind: Shape.Failable, elem: integer)
let graphCell = Value(kind: Flavor.Global, name: "graph_cell",
  `type`: `Type`(kind: Shape.Ptr, elem: integer))
proc number(value: string): Value =
  Value(kind: Flavor.Const, name: value, `type`: integer)
proc local(name: string; typ: `Type`): Value =
  Value(kind: Flavor.Reg, name: name, `type`: typ)
let index = local("graph_index", integer)
let next = local("graph_next", integer)
let more = local("graph_more", boolean)
let failure = local("graph_failure", failable)
let recovered = local("graph_recovered", integer)
let matched = local("graph_matched", boolean)
let graphCheck = Function(name: "graph_check", abi: "c", public: true,
  ret: boolean,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Defer,
      fallback: Block(label: "defer_entry", term:
        Instruction(kind: Opcode.Jump, label: "defer_loop",
          args: @[number("0")])),
      fallbackBlocks: @[
        Block(label: "defer_loop", params: @[index], instrs: @[
          Instruction(kind: Opcode.Compare, op: "is less than",
            dest: more, val: index, val2: number("3"))],
          term: Instruction(kind: Opcode.Cjump, cond: more,
            yes: "defer_body", no: "defer_end")),
        Block(label: "defer_body", instrs: @[
          Instruction(kind: Opcode.Add, dest: next, val: index,
            val2: number("1")),
          Instruction(kind: Opcode.Store, `ptr`: graphCell, val: next)],
          term: Instruction(kind: Opcode.Jump, label: "defer_loop",
            args: @[next])),
        Block(label: "defer_end", term:
          Instruction(kind: Opcode.Return))]),
    Instruction(kind: Opcode.Construct, op: "error", dest: failure,
      args: @[Value(kind: Flavor.Const, name: "ExpectedError",
        `type`: `Type`(kind: Shape.Error))]),
    Instruction(kind: Opcode.Catch, dest: recovered, val: failure,
      fallback: Block(label: "catch_entry", term:
        Instruction(kind: Opcode.Cjump,
          cond: Value(kind: Flavor.Const, name: "false", `type`: boolean),
          yes: "catch_wrong", no: "catch_right")),
      fallbackBlocks: @[
        Block(label: "catch_wrong", term:
          Instruction(kind: Opcode.Return, value: number("40"))),
        Block(label: "catch_right", term:
          Instruction(kind: Opcode.Return, value: number("42")))]),
    Instruction(kind: Opcode.Compare, op: "equals", dest: matched,
      val: recovered, val2: number("42"))],
    term: Instruction(kind: Opcode.Return, value: matched))])
let boot = """
.section .multiboot,"a"
.balign 4
.long 0x1badb002
.long 3
.long -(0x1badb002 + 3)
.section .text.boot,"ax"
.code32
.globl _start
_start:
cli
mov $stack_top, %esp
mov $pml4, %edi
xor %eax, %eax
mov $3072, %ecx
rep stosl
mov $pdpt, %eax
or $3, %eax
mov %eax, pml4
mov $pd, %eax
or $3, %eax
mov %eax, pdpt
movl $0x83, pd
mov $pml4, %eax
mov %eax, %cr3
mov %cr4, %eax
or $0x620, %eax
mov %eax, %cr4
mov $0xc0000080, %ecx
rdmsr
or $0x100, %eax
wrmsr
lgdt gdtr
mov %cr0, %eax
and $0xfffffff3, %eax
or $0x80000000, %eax
mov %eax, %cr0
ljmp $0x08, $long_start
.code64
long_start:
mov $stack_top, %rsp
lea foo.irq(%rip), %rax
mov %ax, idt+512(%rip)
shr $16, %rax
mov %ax, idt+518(%rip)
shr $16, %rax
mov %eax, idt+520(%rip)
movw $8, idt+514(%rip)
movb $0x8e, idt+517(%rip)
lea foo.page_fault(%rip), %rax
mov %ax, idt+224(%rip)
shr $16, %rax
mov %ax, idt+230(%rip)
shr $16, %rax
mov %eax, idt+232(%rip)
movw $8, idt+226(%rip)
movb $0x8e, idt+229(%rip)
lidt idtr(%rip)
mov $85, %r12
mov $0x123456789abcdef0, %rax
movq %rax, %xmm15
int $0x20
movq $0, storage.counter(%rip)
movb $0x11, %al
outb %al, $0x20
outb %al, $0xa0
movb $0x20, %al
outb %al, $0x21
movb $0x28, %al
outb %al, $0xa1
movb $4, %al
outb %al, $0x21
movb $2, %al
outb %al, $0xa1
movb $1, %al
outb %al, $0x21
outb %al, $0xa1
movb $0xfe, %al
outb %al, $0x21
movb $0xff, %al
outb %al, $0xa1
movb $0x34, %al
outb %al, $0x43
movb $0, %al
outb %al, $0x40
outb %al, $0x40
sti
hlt
cli
cmp $85, %r12
jne failed
movq %xmm15, %rax
mov $0x123456789abcdef0, %rcx
cmp %rcx, %rax
jne failed
mov storage.counter(%rip), %rax
cmp $1, %rax
jne failed
mov $0x400000, %rax
movq $0, (%rax)
movq (%rax), %rax
cmp $0, %rax
jne failed
mov storage.fault_code(%rip), %rax
cmp $2, %rax
jne failed
mov storage.fault_count(%rip), %rax
cmp $1, %rax
jne failed
call graph_check
cmp $1, %eax
jne failed
mov storage.graph_cell(%rip), %eax
cmp $3, %eax
jne failed
mov $88, %al
outb %al, $0xe9
1: hlt
jmp 1b
failed:
mov $70, %al
outb %al, $0xe9
2: hlt
jmp 2b
.balign 8
gdt:
.quad 0
.quad 0x00af9a000000ffff
.quad 0x00cf92000000ffff
gdt_end:
gdtr:
.word gdt_end-gdt-1
.long gdt
idtr:
.word 4095
.quad idt
.section .bss,"aw",@nobits
.balign 4096
pml4: .skip 4096
pdpt: .skip 4096
pd: .skip 4096
.balign 16
idt: .skip 4096
stack: .skip 16384
stack_top:
.text
.globl map_fault_page
map_fault_page:
movq $0x400083, pd+16(%rip)
mov $0x400000, %rax
invlpg (%rax)
ret
"""

let program = Module(name: "qbe-x64-irq-delivery", requires: "machine",
  storage: @[
    Storage(name: "counter", value: Value(kind: Flavor.Const,
      name: "0", `type`: natural)),
    Storage(name: "fault_code", value: Value(kind: Flavor.Const,
      name: "0", `type`: natural)),
    Storage(name: "fault_count", value: Value(kind: Flavor.Const,
      name: "0", `type`: natural)),
    Storage(name: "graph_cell", value: number("0"))],
  externs: @[Extern(name: "map_fault_page", symbol: "map_fault_page",
    abi: "c", ret: unit)],
  native: @[Contract(id: "bootAssembly", stage: "@asm", code: boot,
    abi: "foo:1", effects: @["unknown"])], funcs: @[
    Function(name: "irq", ret: unit, attributes: @["interrupt"],
      blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Store, `ptr`: counter,
          val: Value(kind: Flavor.Const, name: "1", `type`: natural))],
        term: Instruction(kind: Opcode.Return))]),
    Function(name: "page_fault", ret: unit, params: @[errorCode],
      attributes: @["interrupt_error_code"], blocks: @[
      Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Store, `ptr`: faultCode, val: errorCode),
        Instruction(kind: Opcode.Store, `ptr`: faultCount,
          val: Value(kind: Flavor.Const, name: "1", `type`: natural)),
        Instruction(kind: Opcode.Call, `func`: "map_fault_page")],
        term: Instruction(kind: Opcode.Return))]),
    graphCheck])

discard seal(program)
for mode in ["dev", "release"]:
  let output = ".artifacts/qbe-x64-irqdelivery/" & mode
  let built = build(program, mode, output,
    Native(name: "qbe-x64-irq-delivery", target: "x64-freestanding",
      runtime: "none", script: "test/backend/qbe/fixtures/x64/irq/link.ld"))
  doAssert built.success, mode & ": " & built.error
  let source = readFile(output / "main-linux.s")
  doAssert "foo.qbe.interrupt.irq" in source
  doAssert "iretq" in source
  doAssert "movq 120(%rdi), %rdi" in source
  doAssert "addq $8, %rsp" in source
  echo mode & ": " & built.artifact
