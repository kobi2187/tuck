#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long primes(long n){ char *c=calloc(n+1,1); long count=0;
  for(long i=2;i<n;i++) if(!c[i]){count++; for(long j=i*i;j<n;j+=i)c[j]=1;} free(c); return count; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 100;
  printf("%ld\n", primes(n));
  return 0;
}
