#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long *randoms(long n,long seed,long modulus){ long *o=malloc(n*sizeof(long)); long s=seed;
  for(long i=0;i<n;i++){ s=(s*1103515245+12345)%2147483648L; o[i]=s%modulus; } return o; }
static long part(long *a,long lo,long hi){ long pv=a[hi],i=lo; for(long j=lo;j<hi;j++) if(a[j]<pv){long t=a[i];a[i]=a[j];a[j]=t;i++;} long t=a[i];a[i]=a[hi];a[hi]=t; return i; }
static void qs(long *a,long lo,long hi){ if(lo>=hi) return; long p=part(a,lo,hi); qs(a,lo,p-1); qs(a,p+1,hi); }
static long checksum(long *a,long n){ long s=0; for(long i=0;i<n;i++) s=(s+a[i]*(i%7+1))%1000000007L; return s; }

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  long *a=randoms(n,7,1000000); qs(a,0,n-1); printf("%ld\n", checksum(a,n));
  return 0;
}
