.text
.macro scalar bits, load, store, value
    .globl foo_qbe_volatile_load\bits
foo_qbe_volatile_load\bits:
    .if \bits == 32
        movl (%rdi), %eax
    .else
        \load (%rdi), %rax
    .endif
    ret
    .globl foo_qbe_volatile_store\bits
foo_qbe_volatile_store\bits:
    \store \value, (%rdi)
    ret
.endm
scalar 8, movzbq, movb, %sil
scalar 16, movzwq, movw, %si
scalar 32, movl, movl, %esi
scalar 64, movq, movq, %rsi

.globl foo_qbe_volatile_read
foo_qbe_volatile_read:
    xorq %rax, %rax
1:
    cmpq %rdx, %rax
    jae 2f
    movb (%rsi,%rax), %cl
    movb %cl, (%rdi,%rax)
    incq %rax
    jmp 1b
2:
    ret

.globl foo_qbe_volatile_write
.set foo_qbe_volatile_write, foo_qbe_volatile_read
