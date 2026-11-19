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
