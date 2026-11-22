ENTRY(Reset_Handler)
MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 256K
  RAM (rwx)  : ORIGIN = 0x20000000, LENGTH = 64K
}
SECTIONS
{
  .text : { KEEP(*(.isr_vector)) *(.text*) *(.rodata*) } > FLASH
  .data : AT (ADDR(.text) + SIZEOF(.text)) {
    _sdata = .;
    *(.data*)
    /* Nim's TLS access reads its offset from the GOT. Copy it with .data so
       it is initialised however the loader treats RAM segments. */
    *(.got) *(.got.plt)
    . = ALIGN(4);   /* Reset_Handler copies whole words up to _edata */
    _edata = .;
  } > RAM
  _sidata = LOADADDR(.data);
  .bss (NOLOAD) : {
    _sbss = .;
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);   /* ...and zeroes whole words up to _ebss */
    _ebss = .;
  } > RAM
  . = ALIGN(4);
  _end = .;
}
