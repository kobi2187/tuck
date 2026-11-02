#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  static long cnt[1000]; long s=5;
  for(long i=0;i<n;i++){ s=(s*1103515245+12345)%2147483648L; cnt[s%1000]++; }
  long r=0; for(int k=0;k<1000;k++) if(cnt[k]) r=(r*31+cnt[k])%1000000007L;
  printf("%ld\n", r);
  return 0;
}
