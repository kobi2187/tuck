#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long ack(long m,long n){ return m==0?n+1: n==0?ack(m-1,1): ack(m-1,ack(m,n-1)); }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 8;
  printf("%ld\n", ack(3,n));
  return 0;
}
