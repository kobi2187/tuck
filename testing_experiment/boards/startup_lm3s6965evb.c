/* Cortex-M3 startup: full vector table + reset handler + default fault
   recorder. The recorder captures the stacked PC/LR/xPSR and the fault
   status registers, then prints a one-line report over semihosting and
   halts. This is the foundation of `tuck decode-crash` on metal. */

extern int main(void);
void Reset_Handler(void);

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

static char hexbuf[128];
static const char *hexdig = "0123456789abcdef";
static void appendHex(char *b, int *i, unsigned int v) {
  for (int k = 28; k >= 0; k -= 4) b[(*i)++] = hexdig[(v >> k) & 0xf];
}

static void recordFault(unsigned int *sp) {
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
  hexbuf[i++] = '\n';
  hexbuf[i] = 0;
  sh(hexbuf);
  for (;;) {}   /* halt; the record is in RAM for a debugger */
}

static void defaultHandler(void) {
  unsigned int *sp;
  __asm volatile("mov %0, sp" : "=r"(sp));
  recordFault(sp);
}

/* --- vector table ------------------------------------------------------- */
__attribute__((section(".isr_vector"), used))
const unsigned int vectors[] = {
  0x20010000,                 /* 0:  initial stack pointer  */
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
  main();
  for (;;) {}
}
