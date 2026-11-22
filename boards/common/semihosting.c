/* The board console and exit over ARM semihosting: what every QEMU board in
   boards/ uses. These are two of the three board hooks the Tuck runtime calls
   (the third, tuck_fatal, is in startup_cortex_m.c and prints through
   tuck_board_puts):

     void tuck_board_puts(const char *s)   write a NUL-terminated string
     void tuck_board_exit(int rc)          end the run with status rc

   Semihosting works only with a debugger or QEMU attached: on silicon with
   neither, BKPT 0xAB escalates to HardFault (a lockup inside the fault
   handler). A board for real hardware supplies its own file with the same two
   functions over a UART, ITM or RTT, and names it in its board.conf. */

/* SYS_WRITE0 (0x04): write a NUL-terminated string to the host console. */
void tuck_board_puts(const char *s) {
  register unsigned int r0 asm("r0") = 4;
  register const char *r1 asm("r1") = s;
  __asm volatile("bkpt 0xab" :: "r"(r0), "r"(r1) : "memory");
}

/* SYS_EXIT_EXTENDED (0x20) with ADP_Stopped_ApplicationExit and a subcode:
   QEMU exits with `rc`, so `tuck sim` sees main's return value. */
void tuck_board_exit(int rc) {
  static volatile unsigned int block[2];
  block[0] = 0x20026u;           /* ADP_Stopped_ApplicationExit */
  block[1] = (unsigned int)rc;
  register unsigned int r0 asm("r0") = 0x20;
  register volatile unsigned int *r1 asm("r1") = block;
  __asm volatile("bkpt 0xab" :: "r"(r0), "r"(r1) : "memory");
  for (;;) {}
}
