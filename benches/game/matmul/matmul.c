#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long cell(long i,long j){ return (i*j+i+j)%7; }
static long *matrix(long n,long salt){ long *m=malloc(n*n*sizeof(long)); for(long i=0;i<n;i++)for(long j=0;j<n;j++)m[i*n+j]=cell(i+salt,j); return m; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 50;
  long *a=matrix(n,0),*b=matrix(n,3),*c=calloc(n*n,sizeof(long));
  for(long i=0;i<n;i++)for(long k=0;k<n;k++){ long aik=a[i*n+k]; for(long j=0;j<n;j++) c[i*n+j]+=aik*b[k*n+j]; }
  long s=0; for(long i=0;i<n*n;i++) s=(s+c[i])%1000003;
  printf("%ld\n", s);
  return 0;
}
