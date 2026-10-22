.text
.balign 4
.macro scalar bits, load, store
    .globl foo_qbe_volatile_load\bits
foo_qbe_volatile_load\bits:
    \load a0, 0(a0)
    ret
    .globl foo_qbe_volatile_store\bits
foo_qbe_volatile_store\bits:
    \store a1, 0(a0)
    ret
.endm
scalar 8, lbu, sb
scalar 16, lhu, sh
scalar 32, lwu, sw
scalar 64, ld, sd

.globl foo_qbe_volatile_read
foo_qbe_volatile_read:
    li t0, 0
1:
    bgeu t0, a2, 2f
    add t1, a1, t0
    lbu t1, 0(t1)
    add t2, a0, t0
    sb t1, 0(t2)
    addi t0, t0, 1
    j 1b
2:
    ret

.globl foo_qbe_volatile_write
.set foo_qbe_volatile_write, foo_qbe_volatile_read
