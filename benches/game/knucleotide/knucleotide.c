#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define IM 139968
#define IA 3877
#define IC 29573
typedef struct { unsigned long key; long val; int used; } Slot;
static long count_of(const unsigned char *dna, long n, const char *word) {
  long k = strlen(word);
  unsigned long mod = 1; for (long i = 0; i < k; i++) mod *= 4;
  unsigned long cap = 8; while (cap < (unsigned long)n * 2 + 2) cap *= 2;
  Slot *t = calloc(cap, sizeof(Slot));
  unsigned long code = 0;
  for (long i = 0; i < n; i++) {
    code = (code * 4 + dna[i]) % mod;
    if (i >= k - 1) {
      unsigned long h = code * 0x9e3779b97f4a7c15UL, j = (h >> 20) & (cap - 1);
      while (t[j].used && t[j].key != code) j = (j + 1) & (cap - 1);
      t[j].used = 1; t[j].key = code; t[j].val++;
    }
  }
  unsigned long want = 0;
  for (long i = 0; i < k; i++) {
    char c = word[i]; int v = c == 'C' ? 1 : c == 'G' ? 2 : c == 'T' ? 3 : 0;
    want = want * 4 + v;
  }
  unsigned long h = want * 0x9e3779b97f4a7c15UL, j = (h >> 20) & (cap - 1);
  long r = 0;
  while (t[j].used) { if (t[j].key == want) { r = t[j].val; break; } j = (j + 1) & (cap - 1); }
  free(t);
  return r;
}
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  unsigned char *dna = malloc(n);
  long seed = 42;
  for (long i = 0; i < n; i++) {
    seed = (seed * IA + IC) % IM;
    double r = (double)seed / IM;
    dna[i] = r < 0.3029549426680 ? 0 : r < 0.5009432431601 ? 1 : r < 0.6984905497992 ? 2 : 3;
  }
  const char *words[] = {"A","C","G","T","AA","AT","GG","GGT","GGTA","GGTATT","GGTATTTTAATT","GGTATTTTAATTTATAGT"};
  for (int i = 0; i < 12; i++) printf("%ld\t%s\n", count_of(dna, n, words[i]), words[i]);
  return 0;
}
