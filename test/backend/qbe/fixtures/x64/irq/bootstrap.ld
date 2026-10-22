ENTRY(_start)
SECTIONS {
  . = 0x200000;
  .multiboot : { KEEP(*(.multiboot)) }
  .text : { *(.text*) }
}
