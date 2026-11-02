/* fannkuch-redux reference: the same algorithm as fannkuch.tuck, plain C. */
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  int n = argc > 1 ? atoi(argv[1]) : 7;
  int perm[16], count[16], p[16], checksum = 0, maxFlips = 0, sign = 1, r = n;
  for (int i = 0; i < n; i++) perm[i] = count[i] = i;
  for (;;) {
    for (; r != 1; r--) count[r - 1] = r;
    for (int i = 0; i < n; i++) p[i] = perm[i];
    int f = 0;
    while (p[0] != 0) {
      for (int lo = 0, hi = p[0]; lo < hi; lo++, hi--) { int t = p[lo]; p[lo] = p[hi]; p[hi] = t; }
      f++;
    }
    if (f > maxFlips) maxFlips = f;
    checksum += sign * f; sign = -sign;
    for (;;) {
      if (r == n) { printf("%d\nPfannkuchen(%d) = %d\n", checksum, n, maxFlips); return 0; }
      int first = perm[0];
      for (int i = 0; i < r; i++) perm[i] = perm[i + 1];
      perm[r] = first;
      if (--count[r] > 0) break;
      r++;
    }
  }
}
