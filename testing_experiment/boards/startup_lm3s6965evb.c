/* Cortex-M3 startup: vector table + reset handler with .data/.bss init. */
extern int main(void);
void Reset_Handler(void);

/* Provided by the linker script (lm3s6965evb.ld). */
extern unsigned int _sidata, _sdata, _edata, _sbss, _ebss;

__attribute__((section(".isr_vector"), used))
const unsigned int vectors[] = {
  0x20010000,                 /* initial stack pointer (top of 64K RAM) */
  ((unsigned int)Reset_Handler + 1) /* reset vector, Thumb bit set */
};

void Reset_Handler(void) {
  unsigned int *src = &_sidata;
  unsigned int *dst = &_sdata;
  while (dst < &_edata) *dst++ = *src++;
  dst = &_sbss;
  while (dst < &_ebss) *dst++ = 0;
  main();
  for (;;) {}
}
