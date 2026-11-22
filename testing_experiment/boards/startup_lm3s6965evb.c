/* Cortex-M3 startup: full vector table + reset handler + default fault
   recorder. The recorder captures the stacked PC/LR/xPSR and the fault
   status registers, then prints a one-line report over semihosting and
   halts. This is the foundation of `tuck decode-crash` on metal. */

extern int main(void);
void Reset_Handler(void);

/* Shared Cortex-M3 startup. The board profile passes its SRAM top so the
   vector table's initial SP matches the linked RAM size. */
#ifndef TUCK_INITIAL_SP
#define TUCK_INITIAL_SP 0x20010000
#endif

/* --- fault record (read by a debugger / post-mortem dumper) ---------- */
typedef struct {
  unsigned int pc;      /* stacked PC: where the faulting instruction was */
  unsigned int lr;      /* stacked LR */
  unsigned int xpsr;    /* stacked xPSR */
  unsigned int cfsr;    /* Configurable Fault Status (0xE000ED28) */
  unsigned int hfsr;    /* HardFault Status (0xE000ED2C) */
  unsigned int bfar;    /* BusFault Address (0xE000ED38) */
  unsigned int magic;   /* 0xF007BAAD when a fault was recorded */
} FaultRecord;

FaultRecord faultRecord = {0};

/* Semihost SYS_WRITE0, so the report reaches the host without a UART. */
static void sh(const char *s) {
  register unsigned int r0 asm("r0") = 4;
  register const char *r1 asm("r1") = s;
  __asm volatile("bkpt 0xab" :: "r"(r0), "r"(r1) : "memory");
}

/* End the run with `rc` as the QEMU exit status: semihosting
   SYS_EXIT_EXTENDED (0x20) with ADP_Stopped_ApplicationExit and a subcode.
   This board file is for QEMU. On silicon with no debugger attached a BKPT
   escalates to HardFault, so a real-board startup defines tuck_board_exit as
   an idle loop (or a reset) instead and routes output to a UART. */
void tuck_board_exit(int rc) {
#ifdef TUCK_NO_SEMIHOST_EXIT
  (void)rc;
#else
  static volatile unsigned int block[2];
  block[0] = 0x20026u;           /* ADP_Stopped_ApplicationExit */
  block[1] = (unsigned int)rc;
  register unsigned int r0 asm("r0") = 0x20;
  register volatile unsigned int *r1 asm("r1") = block;
  __asm volatile("bkpt 0xab" :: "r"(r0), "r"(r1) : "memory");
#endif
  for (;;) {}
}

/* A runtime check failed (bounds, overflow, heap exhausted, a Nim panic).
   Say what, then trap: the undefined instruction is a UsageFault, so the
   recorder below prints the FAULT line and ends the run with status 1. */
void tuck_fatal(const char *msg) __attribute__((noreturn));
void tuck_fatal(const char *msg) {
  /* Read the return address first: the stacked LR of the trap is then the
     instruction after the failing check's call, which DWARF built with
     --debug-lines maps to the Tuck line. */
  void *caller = __builtin_return_address(0);
  sh("PANIC: ");
  sh(msg);
  sh("\n");
  __asm volatile("mov lr, %0\n\tudf #0" :: "r"(caller) : "lr");
  for (;;) {}
}

static char hexbuf[128];
static const char *hexdig = "0123456789abcdef";
static void appendHex(char *b, int *i, unsigned int v) {
  for (int k = 28; k >= 0; k -= 4) b[(*i)++] = hexdig[(v >> k) & 0xf];
}

__attribute__((used)) static void recordFault(unsigned int *sp) {
  /* Stacked frame layout (low -> high): xPSR, PC, LR, R12, R3, R2, R1, R0.
     sp points at R0, so PC is at sp+6, LR at sp+5, xPSR at sp+7. */
  faultRecord.pc = sp[6];
  faultRecord.lr = sp[5];
  faultRecord.xpsr = sp[7];
  faultRecord.cfsr = *(volatile unsigned int *)0xE000ED28u;
  faultRecord.hfsr = *(volatile unsigned int *)0xE000ED2Cu;
  faultRecord.bfar = *(volatile unsigned int *)0xE000ED38u;
  faultRecord.magic = 0xF007BAADu;

  int i = 0;
  const char *p = "FAULT PC=";
  for (; *p; p++) hexbuf[i++] = *p;
  appendHex(hexbuf, &i, faultRecord.pc);
  const char *q = " LR=";
  for (; *q; q++) hexbuf[i++] = *q;
  appendHex(hexbuf, &i, faultRecord.lr);
  const char *r = " CFSR=";
  for (; *r; r++) hexbuf[i++] = *r;
  appendHex(hexbuf, &i, faultRecord.cfsr);
  const char *s = " HFSR=";
  for (; *s; s++) hexbuf[i++] = *s;
  appendHex(hexbuf, &i, faultRecord.hfsr);
  /* BFAR is only valid when CFSR.BFARVALID is set; we print it unconditionally
     so the host decoder can decide from the bit instead of a missing field. */
  const char *t = " BFAR=";
  for (; *t; t++) hexbuf[i++] = *t;
  appendHex(hexbuf, &i, faultRecord.bfar);
  const char *u = " xPSR=";
  for (; *u; u++) hexbuf[i++] = *u;
  appendHex(hexbuf, &i, faultRecord.xpsr);
  hexbuf[i++] = '\n';
  hexbuf[i] = 0;
  sh(hexbuf);
  /* The record stays in RAM for a debugger; under QEMU the run ends with
     status 1 instead of idling until the timeout. */
  tuck_board_exit(1);
}

/* NAKED on purpose. A compiled C handler pushes {r7, lr} and reserves a
   local slot before it can read SP, which shifts the exception frame by 4
   words. The old handler printed R1/R2/R3 as LR/PC/xPSR (stage14's "PC in
   RAM" was really R2). Here SP at entry IS the stacked frame, so recordFault
   can index R0/R1/R2/R3/R12/LR/PC/xPSR at sp[0..7]. */
__attribute__((naked)) static void defaultHandler(void) {
  __asm volatile("mov r0, sp\n"
                 "b recordFault\n");
}

/* --- vector table ------------------------------------------------------- */
__attribute__((section(".isr_vector"), used))
const unsigned int vectors[] = {
  TUCK_INITIAL_SP,            /* 0:  initial stack pointer  */
  ((unsigned int)Reset_Handler + 1), /* 1: reset */
  ((unsigned int)defaultHandler + 1), /* 2: NMI */
  ((unsigned int)defaultHandler + 1), /* 3: HardFault */
  ((unsigned int)defaultHandler + 1), /* 4: MemManage */
  ((unsigned int)defaultHandler + 1), /* 5: BusFault */
  ((unsigned int)defaultHandler + 1), /* 6: UsageFault */
  0,                            /* 7: reserved */
  0,                            /* 8: reserved */
  0,                            /* 9: reserved */
  0,                            /* 10: reserved */
  ((unsigned int)defaultHandler + 1), /* 11: SVCall */
  ((unsigned int)defaultHandler + 1), /* 12: DebugMon */
  0,                            /* 13: reserved */
  ((unsigned int)defaultHandler + 1), /* 14: PendSV */
  ((unsigned int)defaultHandler + 1), /* 15: SysTick */
};

void Reset_Handler(void) {
  extern unsigned int _sidata, _sdata, _edata, _sbss, _ebss;
  unsigned int *src = &_sidata;
  unsigned int *dst = &_sdata;
  while (dst < &_edata) *dst++ = *src++;
  dst = &_sbss;
  while (dst < &_ebss) *dst++ = 0;
  /* Trap unaligned word accesses. With this on, an unaligned store in a
     directly called shim faults AT that instruction (precise UsageFault), which lets
     `tuck decode-crash` name the Tuck line. QEMU's stellaris board silently
     ignores stores to unmapped addresses, so this is the reliable way to
     produce a precise fault from Tuck-generated code on this board. */
  *(volatile unsigned int *)0xE000ED14u |= (1u << 3);  /* CCR.UNALIGN_TRP */
  main();
  for (;;) {}
}
