#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long tak(long x,long y,long z){ return y<x ? tak(tak(x-1,y,z),tak(y-1,z,x),tak(z-1,x,y)) : z; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 10;
  printf("%ld\n", tak(3*n,2*n,n));
  return 0;
}
