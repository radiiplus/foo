.section .multiboot,"a"
.balign 4
.long 0x1badb002
.long 3
.long -(0x1badb002 + 3)
.text
.code32
.globl _start
_start:
    mov $0x100010, %eax
    jmp *%eax
