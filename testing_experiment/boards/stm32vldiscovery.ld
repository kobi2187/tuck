ENTRY(Reset_Handler)
/* QEMU's stm32vldiscovery maps 128K flash at 0x08000000 with an alias at 0x0,
   and 8K SRAM at 0x20000000. Link to the alias so -kernel loads at 0. */
MEMORY
{
  FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 128K
  RAM (rwx)  : ORIGIN = 0x20000000, LENGTH = 8K
}
SECTIONS
{
  .text : { KEEP(*(.isr_vector)) *(.text*) *(.rodata*) } > FLASH
  .data : AT (ADDR(.text) + SIZEOF(.text)) {
    _sdata = .;
    *(.data*)
    /* Nim's TLS access reads its offset from the GOT. Copy it with .data:
       QEMU loads only the flash segment for this board, so a RAM segment
       left to the ELF loader stays uninitialised. */
    *(.got) *(.got.plt)
    _edata = .;
  } > RAM
  _sidata = LOADADDR(.data);
  .bss (NOLOAD) : {
    _sbss = .;
    *(.bss*)
    *(COMMON)
    _ebss = .;
  } > RAM
  . = ALIGN(4);
  _end = .;
}
