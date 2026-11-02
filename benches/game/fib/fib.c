#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long fib(long n){ return n<2?n:fib(n-1)+fib(n-2); }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 20;
  printf("%ld\n", fib(n));
  return 0;
}
