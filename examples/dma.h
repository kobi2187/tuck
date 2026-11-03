/* A stand-in for a DMA controller: fills a buffer the caller gave it. */
#ifndef TUCK_DMA_H
#define TUCK_DMA_H
void dmaFill(unsigned char *p, long c, long n);
#endif
