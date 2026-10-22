.text
.balign 4
.globl foo_qbe_atomic_fence
foo_qbe_atomic_fence:
    dmb ish
    ret

# Stronger barriers cover all accepted memory orders, including seq_cst.
.macro lane bits, suffix, reg
    .globl foo_qbe_atomic_load\bits
foo_qbe_atomic_load\bits:
    dmb ish
    ldar\suffix \reg\()0, [x0]
    dmb ish
    ret

    .globl foo_qbe_atomic_store\bits
foo_qbe_atomic_store\bits:
    dmb ish
    stlr\suffix \reg\()1, [x0]
    dmb ish
    ret

    .globl foo_qbe_atomic_add\bits
foo_qbe_atomic_add\bits:
    dmb ish
1:
    ldxr\suffix \reg\()3, [x0]
    add \reg\()5, \reg\()3, \reg\()1
    stxr\suffix w4, \reg\()5, [x0]
    cbnz w4, 1b
    mov \reg\()0, \reg\()3
    dmb ish
    ret

    .globl foo_qbe_atomic_sub\bits
foo_qbe_atomic_sub\bits:
    dmb ish
1:
    ldxr\suffix \reg\()3, [x0]
    sub \reg\()5, \reg\()3, \reg\()1
    stxr\suffix w4, \reg\()5, [x0]
    cbnz w4, 1b
    mov \reg\()0, \reg\()3
    dmb ish
    ret

    .globl foo_qbe_atomic_swap\bits
foo_qbe_atomic_swap\bits:
    dmb ish
1:
    ldxr\suffix \reg\()3, [x0]
    stxr\suffix w4, \reg\()1, [x0]
    cbnz w4, 1b
    mov \reg\()0, \reg\()3
    dmb ish
    ret
.endm

lane 8, b, w
lane 16, h, w
lane 32, , w
lane 64, , x
