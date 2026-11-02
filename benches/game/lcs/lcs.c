#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long *randoms(long n,long seed,long modulus){ long *o=malloc(n*sizeof(long)); long s=seed;
  for(long i=0;i<n;i++){ s=(s*1103515245+12345)%2147483648L; o[i]=s%modulus; } return o; }
static long lcs(long *a,long na,long *b,long nb){ long *prev=calloc(nb+1,sizeof(long)),*cur=calloc(nb+1,sizeof(long));
  for(long i=1;i<=na;i++){ cur[0]=0; for(long j=1;j<=nb;j++){ long v=prev[j]; if(a[i-1]==b[j-1]) v=prev[j-1]+1; else if(cur[j-1]>v) v=cur[j-1]; cur[j]=v; } long *t=prev;prev=cur;cur=t; }
  return prev[nb]; }

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 500;
  long *a=randoms(n,3,4),*b=randoms(n,5,4); printf("%ld\n", lcs(a,n,b,n));
  return 0;
}
