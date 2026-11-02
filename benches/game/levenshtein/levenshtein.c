#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long *randoms(long n,long seed,long modulus){ long *o=malloc(n*sizeof(long)); long s=seed;
  for(long i=0;i<n;i++){ s=(s*1103515245+12345)%2147483648L; o[i]=s%modulus; } return o; }
static long distance(long *a,long na,long *b,long nb){ long *prev=malloc((nb+1)*sizeof(long)),*cur=malloc((nb+1)*sizeof(long));
  for(long j=0;j<=nb;j++)prev[j]=j;
  for(long i=1;i<=na;i++){ cur[0]=i; for(long j=1;j<=nb;j++){ long best=prev[j-1]+(a[i-1]!=b[j-1]); long up=prev[j]+1; if(up<best)best=up; long left=cur[j-1]+1; if(left<best)best=left; cur[j]=best; } long *t=prev;prev=cur;cur=t; }
  return prev[nb]; }

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 500;
  long *a=randoms(n,1,4),*b=randoms(n,2,4); printf("%ld\n", distance(a,n,b,n));
  return 0;
}
