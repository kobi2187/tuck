#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static long permutations(long n){ long a[32],c[32]; for(long i=0;i<n;i++){a[i]=i;c[i]=0;} long sum=0,count=1,i=0;
  while(i<n){ if(c[i]<i){ if(i%2==0){long t=a[0];a[0]=a[i];a[i]=t;} else {long t=a[c[i]];a[c[i]]=a[i];a[i]=t;} c[i]++; count++; sum=(sum+a[0]*31+a[n-1])%1000000007L; i=0; } else { c[i]=0; i++; } }
  return sum*7+count; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 9;
  printf("%ld\n", permutations(n));
  return 0;
}
