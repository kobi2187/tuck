#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#define SZ (1<<22)
static long keys[SZ], vals[SZ]; static char used[SZ];
static void put(long k,long v){ unsigned long h=(unsigned long)k*0x9E3779B97F4A7C15UL>>42; while(used[h]&&keys[h]!=k) h=(h+1)&(SZ-1); used[h]=1;keys[h]=k;vals[h]=v; }
static int get(long k,long *v){ unsigned long h=(unsigned long)k*0x9E3779B97F4A7C15UL>>42; while(used[h]){ if(keys[h]==k){*v=vals[h];return 1;} h=(h+1)&(SZ-1);} return 0; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  long s=1; for(long i=0;i<n;i++){ s=(s*1103515245+12345)%2147483648L; put(s%1000003,i); }
  long hits=0; s=1; for(long i=0;i<n;i++){ s=(s*1103515245+12345)%2147483648L; long v; if(get(s%1000003,&v)) hits+=v%10; }
  printf("%ld\n", hits);
  return 0;
}
