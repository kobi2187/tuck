#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef struct{int tag; long a,b;}T; typedef struct{long kind,value;}Pk;
static long run(long rounds){ T t[4]={{0,0,0},{1,0,7},{2,0,0},{3,0,0}}; Pk p={0,1}; long at=0;
  for(long r=0;r<rounds;r++){ T *x=&t[at]; Pk o;
    switch(x->tag){ case 0: x->a++; o.kind=1;o.value=p.value+1; break;
      case 1: { long acc=(x->b*31+p.value)%1000003; x->a++; x->b=acc; o.kind=2;o.value=acc; break; }
      case 2: { long v= p.value%2==0? p.value/2 : 3*p.value+1; x->a++; x->b=v; o.kind=3;o.value=v; break; }
      default: x->a+=p.value%7; o.kind=0;o.value=p.value; }
    p=o; at=p.kind; }
  long total=0; long sc[4]={t[0].a,t[1].a+t[1].b,t[2].a+t[2].b,t[3].a}; for(int i=0;i<4;i++) total=(total+sc[i])%1000000007L; return total; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  printf("%ld\n", run(n));
  return 0;
}
