#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  double h=1.0/n,sum=0; for(long i=0;i<n;i++){ double x=(i+0.5)*h; sum+=4.0/(1.0+x*x);} printf("%ld\n",(long)(sum*h*1e9));
  return 0;
}
