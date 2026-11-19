  .syntax unified
  .cpu cortex-m3
  .thumb
  .text
  .thumb_func
  .global tuck_semihost_write
  .type tuck_semihost_write, %function
/* r0 = NUL-terminated string pointer; SYS_WRITE0 = 0x04 */
tuck_semihost_write:
  movs r2, #4
  mov  r1, r0
  mov  r0, r2
  bkpt 0xab
  bx lr
  .size tuck_semihost_write, .-tuck_semihost_write
