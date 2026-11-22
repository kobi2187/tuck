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

  .extern tuck_tls
  .thumb_func
  .global __aeabi_read_tp
  .type __aeabi_read_tp, %function
/* ARM EABI: only r0 may change. Nim keeps the TLS GOT offset in r3 across
   this call, so touching r3 here makes every error-flag read fault. */
__aeabi_read_tp:
  ldr r0, .Ltuck_tp
  bx lr
.Ltuck_tp:
  .word tuck_tls + 8
  .size __aeabi_read_tp, .-__aeabi_read_tp
