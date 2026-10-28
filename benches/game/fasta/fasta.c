#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define IM 139968
#define IA 3877
#define IC 29573
static const char *ALU = "GGCCGGGCGCGGTGGCTCACGCCTGTAATCCCAGCACTTTGGGAGGCCGAGGCGGGCGGATCACCTGAGGTCAGGAGTTCGAGACCAGCCTGGCCAACATGGTGAAACCCCGTCTCTACTAAAAATACAAAAATTAGCCGGGCGTGGTGGCGCGCGCCTGTAATCCCAGCTACTCGGGAGGCTGAGGCAGGAGAATCGCTTGAACCCGGGAGGCGGAGGTTGCAGTGAGCCGAGATCGCGCCACTGCACTCCAGCCTGGGCGACAGAGCGAGACTCCGTCTCAAAAA";
typedef struct { char c; double p; } Pick;
static long seed;
static void repeat(const char *id, const char *desc, long n) {
  printf(">%s %s\n", id, desc);
  long size = strlen(ALU), pos = 0;
  while (n > 0) {
    long take = n < 60 ? n : 60;
    for (long k = 0; k < take; k++) { putchar(ALU[pos]); pos = (pos + 1) % size; }
    putchar('\n'); n -= take;
  }
}
static void randomf(const char *id, const char *desc, Pick *t, int tn, long n) {
  printf(">%s %s\n", id, desc);
  while (n > 0) {
    long take = n < 60 ? n : 60;
    for (long k = 0; k < take; k++) {
      seed = (seed * IA + IC) % IM;
      double r = (double)seed / IM;
      int i = 0;
      while (i < tn - 1 && !(r < t[i].p)) i++;
      putchar(t[i].c);
    }
    putchar('\n'); n -= take;
  }
}
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  const char *ic = "acgtBDHKMNRSVWY";
  double ip[] = {0.27,0.12,0.12,0.27,0.02,0.02,0.02,0.02,0.02,0.02,0.02,0.02,0.02,0.02,0.02};
  Pick iub[15], hs[4];
  double acc = 0;
  for (int i = 0; i < 15; i++) { acc += ip[i]; iub[i].c = ic[i]; iub[i].p = acc; }
  double hp[] = {0.3029549426680, 0.1979883004921, 0.1975473066391, 0.3015094502008};
  acc = 0;
  for (int i = 0; i < 4; i++) { acc += hp[i]; hs[i].c = "acgt"[i]; hs[i].p = acc; }
  seed = 42;
  repeat("ONE", "Homo sapiens alu", n * 2);
  randomf("TWO", "IUB ambiguity codes", iub, 15, n * 3);
  randomf("THREE", "Homo sapiens frequency", hs, 4, n * 5);
  return 0;
}
