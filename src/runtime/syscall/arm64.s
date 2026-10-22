.text
.globl foo_qbe_syscall6
.type foo_qbe_syscall6, %function
foo_qbe_syscall6:
    mov x8, x0
    mov x0, x1
    mov x1, x2
    mov x2, x3
    mov x3, x4
    mov x4, x5
    mov x5, x6
    .long 0xd4000001
    ret
.size foo_qbe_syscall6, .-foo_qbe_syscall6
