#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long gcd(long a,long b){ while(b){long t=a%b;a=b;b=t;} return a; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 100;
  long s=0; for(long i=1;i<n;i++)for(long j=1;j<n;j++) s+=gcd(i,j); printf("%ld\n", s);
  return 0;
}
