ENTRY(_start)
SECTIONS {
  /* Leave the board's initial device-tree region free. */
  . = 0x40200000;
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) *(COMMON) }
}
