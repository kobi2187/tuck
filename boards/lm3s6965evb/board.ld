ENTRY(Reset_Handler)
MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 256K
  RAM (rwx)  : ORIGIN = 0x20000000, LENGTH = 64K
}
/* Top of RAM: the vector table's initial SP (boards/common/startup_cortex_m.c).
   Derived from the MEMORY block, so it cannot disagree with the RAM size. */
_estack = ORIGIN(RAM) + LENGTH(RAM);

SECTIONS
{
  .text : { KEEP(*(.isr_vector)) *(.text*) *(.rodata*) } > FLASH
  /* 64 bytes of scratch at the start of RAM, 0x20000000..0x2000003F, kept
     out of .data/.bss. Test programs declare a `register` there when they
     need a word they can write and read back: peripheral space (0x40000000)
     is a real peripheral on every board, and an address in .bss is the
     program's own variables. */
  .scratch (NOLOAD) : { . = . + 64; } > RAM
  .data : AT (ADDR(.text) + SIZEOF(.text)) {
    _sdata = .;
    *(.data*)
    /* A GOT, if the toolchain emits one, is initialised with .data: QEMU's
       loaders do not all initialise RAM segments themselves. */
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
