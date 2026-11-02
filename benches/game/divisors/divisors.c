#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long dc(long x){ long c=0; for(long d=1;d*d<=x;d++) if(x%d==0){c++; if(d*d!=x)c++;} return c; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 100;
  long s=0; for(long i=1;i<=n;i++) s+=dc(i); printf("%ld\n", s);
  return 0;
}
