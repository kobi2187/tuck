#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long *randoms(long n,long seed,long modulus){ long *o=malloc(n*sizeof(long)); long s=seed;
  for(long i=0;i<n;i++){ s=(s*1103515245+12345)%2147483648L; o[i]=s%modulus; } return o; }
static long *step(long *g,long n){ long *o=malloc(n*n*sizeof(long)); for(long y=0;y<n;y++)for(long x=0;x<n;x++){ long c=0;
  for(long dy=0;dy<3;dy++)for(long dx=0;dx<3;dx++) if(dx!=1||dy!=1) c+=g[((y+dy+n-1)%n)*n+(x+dx+n-1)%n];
  long al=g[y*n+x],nx=0; if(al==1&&(c==2||c==3))nx=1; if(al==0&&c==3)nx=1; o[y*n+x]=nx; } free(g); return o; }

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 64;
  long *g=randoms(n*n,9,2); for(int i=0;i<100;i++) g=step(g,n);
  long s=0; for(long i=0;i<n*n;i++) s+=g[i]; printf("%ld\n", s);
  return 0;
}
