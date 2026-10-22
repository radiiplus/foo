.text
.balign 4
.globl foo_qbe_atomic_fence
foo_qbe_atomic_fence:
    fence rw, rw
    ret

.globl foo_qbe_atomic_load32
foo_qbe_atomic_load32:
    fence rw, rw
    lwu a0, 0(a0)
    fence rw, rw
    ret

.globl foo_qbe_atomic_load64
foo_qbe_atomic_load64:
    fence rw, rw
    ld a0, 0(a0)
    fence rw, rw
    ret

.globl foo_qbe_atomic_store32
foo_qbe_atomic_store32:
    fence rw, rw
    sw a1, 0(a0)
    fence rw, rw
    ret

.globl foo_qbe_atomic_store64
foo_qbe_atomic_store64:
    fence rw, rw
    sd a1, 0(a0)
    fence rw, rw
    ret

.globl foo_qbe_atomic_add32
foo_qbe_atomic_add32:
    amoadd.w.aqrl a0, a1, (a0)
    ret

.globl foo_qbe_atomic_add64
foo_qbe_atomic_add64:
    amoadd.d.aqrl a0, a1, (a0)
    ret

.globl foo_qbe_atomic_sub32
foo_qbe_atomic_sub32:
    negw a1, a1
    amoadd.w.aqrl a0, a1, (a0)
    ret

.globl foo_qbe_atomic_sub64
foo_qbe_atomic_sub64:
    neg a1, a1
    amoadd.d.aqrl a0, a1, (a0)
    ret

.globl foo_qbe_atomic_swap32
foo_qbe_atomic_swap32:
    amoswap.w.aqrl a0, a1, (a0)
    ret

.globl foo_qbe_atomic_swap64
foo_qbe_atomic_swap64:
    amoswap.d.aqrl a0, a1, (a0)
    ret

# Subword AMOs operate on their containing aligned word. All writers use the
# same LR/SC reservation, so updates to separate lanes cannot erase each other.
.macro setup bits
    andi t0, a0, -4
    andi t1, a0, 3
    slli t1, t1, 3
    li t2, (1 << \bits) - 1
    sll t3, t2, t1
.endm

.macro load bits
    .globl foo_qbe_atomic_load\bits
foo_qbe_atomic_load\bits:
    setup \bits
    fence rw, rw
    lr.w.aq t4, (t0)
    srl t4, t4, t1
    and a0, t4, t2
    fence rw, rw
    ret
.endm

.macro update bits, operation
    .globl foo_qbe_atomic_\operation\bits
foo_qbe_atomic_\operation\bits:
    setup \bits
    and a1, a1, t2
    fence rw, rw
1:
    lr.w.aq t4, (t0)
    srl t5, t4, t1
    and t5, t5, t2
    .ifc \operation,add
        add t6, t5, a1
    .else
      .ifc \operation,sub
        sub t6, t5, a1
      .else
        mv t6, a1
      .endif
    .endif
    and t6, t6, t2
    sll t6, t6, t1
    not a2, t3
    and a2, a2, t4
    or t6, t6, a2
    sc.w.rl a2, t6, (t0)
    bnez a2, 1b
    fence rw, rw
    mv a0, t5
    ret
.endm

.macro store bits
    .globl foo_qbe_atomic_store\bits
foo_qbe_atomic_store\bits:
    setup \bits
    and a1, a1, t2
    sll a1, a1, t1
    not t3, t3
    fence rw, rw
1:
    lr.w.aq t4, (t0)
    and t4, t4, t3
    or t4, t4, a1
    sc.w.rl t5, t4, (t0)
    bnez t5, 1b
    fence rw, rw
    ret
.endm

load 8
load 16
store 8
store 16
update 8, add
update 16, add
update 8, sub
update 16, sub
update 8, swap
update 16, swap
