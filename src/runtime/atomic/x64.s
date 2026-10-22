.text
.globl foo_qbe_atomic_fence
foo_qbe_atomic_fence:
    mfence
    ret

# Each locked read-modify-write and exchange is stronger than any requested order.
.macro previous bits
    .if \bits == 8
        movzbq %sil, %rax
    .elseif \bits == 16
        movzwq %si, %rax
    .elseif \bits == 32
        movl %esi, %eax
    .else
        movq %rsi, %rax
    .endif
.endm

.macro lane bits, suffix, value, load
    .globl foo_qbe_atomic_load\bits
foo_qbe_atomic_load\bits:
    .if \bits == 32
        movl (%rdi), %eax
    .else
        \load (%rdi), %rax
    .endif
    ret
    .globl foo_qbe_atomic_store\bits
foo_qbe_atomic_store\bits:
    xchg\suffix \value, (%rdi)
    ret
    .globl foo_qbe_atomic_add\bits
foo_qbe_atomic_add\bits:
    lock xadd\suffix \value, (%rdi)
    previous \bits
    ret
    .globl foo_qbe_atomic_sub\bits
foo_qbe_atomic_sub\bits:
    neg\suffix \value
    lock xadd\suffix \value, (%rdi)
    previous \bits
    ret
    .globl foo_qbe_atomic_swap\bits
foo_qbe_atomic_swap\bits:
    xchg\suffix \value, (%rdi)
    previous \bits
    ret
.endm

lane 8, b, %sil, movzbq
lane 16, w, %si, movzwq
lane 32, l, %esi, movl
lane 64, q, %rsi, movq
