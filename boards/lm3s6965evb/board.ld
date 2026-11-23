ENTRY(Reset_Handler)
MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 256K
  RAM (rwx)  : ORIGIN = 0x20000000, LENGTH = 64K
}
/* Top of RAM: the vector table's initial SP (boards/common/startup_cortex_m.c).
   Derived from the MEMORY block, so it cannot disagree with the RAM size. */
_estack = ORIGIN(RAM) + LENGTH(RAM);
/* Bytes kept for the main stack below _estack; the heap ends there. */
_stack_reserve = 0x800;

SECTIONS
{
  /* .ARM.exidx (unwind tables, which --os:any emits) lives in .text, and
     .text ends word-aligned: .data's load image starts right after it and
     Reset_Handler copies it in whole words, which trap when unaligned. */
  .text : {
    KEEP(*(.isr_vector)) *(.text*) *(.rodata*)
    *(.ARM.extab* .gnu.linkonce.armextab.*) *(.ARM.exidx* .gnu.linkonce.armexidx.*)
    . = ALIGN(4);
  } > FLASH
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
  . = ALIGN(8);
  _end = .;
  /* The heap: what picolibc's malloc (sbrk) hands out, for `Seq` and
     strings on metal. It runs from the end of .bss up to a fixed reserve
     below the initial SP; the stack grows down into that reserve. */
  __heap_start = _end;
  __heap_end = _estack - _stack_reserve;
  ASSERT(__heap_end > __heap_start, "no room left for a heap and the stack reserve")
}
