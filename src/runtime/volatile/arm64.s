.text
.balign 4
.macro scalar bits, load, store, reg
    .globl foo_qbe_volatile_load\bits
foo_qbe_volatile_load\bits:
    \load \reg\()0, [x0]
    ret
    .globl foo_qbe_volatile_store\bits
foo_qbe_volatile_store\bits:
    \store \reg\()1, [x0]
    ret
.endm
scalar 8, ldrb, strb, w
scalar 16, ldrh, strh, w
scalar 32, ldr, str, w
scalar 64, ldr, str, x

.globl foo_qbe_volatile_read
foo_qbe_volatile_read:
    mov x3, #0
1:
    cmp x3, x2
    b.hs 2f
    ldrb w4, [x1, x3]
    strb w4, [x0, x3]
    add x3, x3, #1
    b 1b
2:
    ret

.globl foo_qbe_volatile_write
.set foo_qbe_volatile_write, foo_qbe_volatile_read
