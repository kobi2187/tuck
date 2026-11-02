#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long longest(long n){ long best=0,arg=1;
  for(long i=1;i<n;i++){ long x=i,s=0; while(x!=1){ x = x%2==0 ? x/2 : 3*x+1; s++; } if(s>best){best=s;arg=i;} }
  return arg*1000+best%1000; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 100;
  printf("%ld\n", longest(n));
  return 0;
}
