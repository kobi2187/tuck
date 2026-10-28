#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 200, count = 0;
  for (long y = 0; y < n; y++)
    for (long x = 0; x < n; x++) {
      double cr = 2.0 * x / n - 1.5, ci = 2.0 * y / n - 1.0, zr = 0, zi = 0;
      int in = 1;
      for (int k = 0; k < 50; k++) {
        double nr = zr * zr - zi * zi + cr;
        zi = 2.0 * zr * zi + ci; zr = nr;
        if (zr * zr + zi * zi > 4.0) { in = 0; break; }
      }
      count += in;
    }
  printf("%ld\n", count);
  return 0;
}
