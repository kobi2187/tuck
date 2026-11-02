#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  size_t cap=1<<20,len=0; char *s=malloc(cap); char tmp[32];
  for(long i=0;i<n;i++){ int k=sprintf(tmp,"%ld,",i); if(len+k+1>cap){cap*=2;s=realloc(s,cap);} memcpy(s+len,tmp,k); len+=k; }
  long c=0; for(size_t i=0;i<len;i++) if(s[i]>='0'&&s[i]<='9') c++;
  printf("%ld\n", c);
  return 0;
}
