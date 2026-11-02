#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long solve(long *p,long len,long n){ if(len==n) return 1; long count=0;
  for(long col=0;col<n;col++){ int ok=1; for(long r=0;r<len;r++){ long c=p[r]; if(c==col||c-col==len-r||col-c==len-r){ok=0;break;} }
    if(ok){ p[len]=col; count+=solve(p,len+1,n);} } return count; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 8;
  long p[64]; printf("%ld\n", solve(p,0,n));
  return 0;
}
