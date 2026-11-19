  .syntax unified
  .cpu cortex-m3
  .thumb
  .section .isr_vector, "a", %progbits
  .word 0x20010000
  .word Reset_Handler
  .text
  .thumb_func
  .global Reset_Handler
Reset_Handler:
  bl main
  b .
