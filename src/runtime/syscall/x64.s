.text
.globl foo_qbe_syscall6
.type foo_qbe_syscall6, @function
foo_qbe_syscall6:
    movq %rdi, %rax
    movq %rsi, %rdi
    movq %rdx, %rsi
    movq %rcx, %rdx
    movq %r8, %r10
    movq %r9, %r8
    movq 8(%rsp), %r9
    syscall
    ret
.size foo_qbe_syscall6, .-foo_qbe_syscall6
