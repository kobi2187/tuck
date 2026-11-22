  .syntax unified
  .cpu cortex-m3
  .thumb
  .text
  .extern tuck_tls
  .thumb_func
  .global __aeabi_read_tp
  .type __aeabi_read_tp, %function
/* The ARM EABI thread-pointer read, for Nim's threadvar access (its error
   flag), which the freestanding build still emits. EABI: only r0 may change.
   Nim keeps the TLS GOT offset in r3 across this call, so a C version, which
   may clobber r3, made every error-flag read fault. Roadmap 1.2 removes the
   need for this file. */
__aeabi_read_tp:
  ldr r0, .Ltuck_tp
  bx lr
.Ltuck_tp:
  .word tuck_tls + 8
  .size __aeabi_read_tp, .-__aeabi_read_tp
