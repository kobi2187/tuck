#include <stdio.h>
#include <stdlib.h>
#define IM 139968
#define IA 3877
#define IC 29573
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  const char *codes = "acgtBDHKMNRSVWY", *pairs = "TGCAVHDMKNYSBWR";
  unsigned char comp[256] = {0};
  for (int i = 0; i < 15; i++) comp[(unsigned char)codes[i]] = pairs[i];
  unsigned char *dna = malloc(n + 1);
  long seed = 42;
  for (long i = 0; i < n; i++) { seed = (seed * IA + IC) % IM; dna[i] = codes[seed % 15]; }
  unsigned char *rc = malloc(n + 1);
  for (long i = 0; i < n; i++) rc[i] = comp[dna[n - 1 - i]];
  puts(">ONE Reverse complement");
  for (long pos = 0; pos < n; pos += 60) {
    long k = n - pos < 60 ? n - pos : 60;
    fwrite(rc + pos, 1, k, stdout); putchar('\n');
  }
  return 0;
}
