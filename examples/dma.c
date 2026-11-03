#include "dma.h"

void dmaFill(unsigned char *p, long c, long n) {
  for (long i = 0; i < n; i++) p[i] = (unsigned char)c;
}
