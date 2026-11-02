#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long *randoms(long n,long seed,long modulus){ long *o=malloc(n*sizeof(long)); long s=seed;
  for(long i=0;i<n;i++){ s=(s*1103515245+12345)%2147483648L; o[i]=s%modulus; } return o; }
static void sift(long *a,long start,long end){ long root=start; for(;;){ long child=2*root+1; if(child>end) break; if(child+1<=end&&a[child]<a[child+1]) child++; if(a[root]<a[child]){long t=a[root];a[root]=a[child];a[child]=t;root=child;} else break; } }
static long checksum(long *a,long n){ long s=0; for(long i=0;i<n;i++) s=(s+a[i]*(i%7+1))%1000000007L; return s; }

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  long *a=randoms(n,11,1000000);
  for(long s=n/2-1;s>=0;s--) sift(a,s,n-1);
  for(long e=n-1;e>0;){ long t=a[0];a[0]=a[e];a[e]=t; e--; sift(a,0,e); }
  printf("%ld\n", checksum(a,n));
  return 0;
}
