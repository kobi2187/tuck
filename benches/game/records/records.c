#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef struct{long x,y,w;}P;
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  P *ps=malloc(n*sizeof(P)); for(long i=0;i<n;i++){ps[i].x=i;ps[i].y=i*2%17;ps[i].w=1;}
  for(int r=0;r<8;r++) for(long i=0;i<n;i++){ P p=ps[i]; ps[i].x=p.x+r; ps[i].y=p.y*3%101; ps[i].w=p.w+p.y%3; }
  long s=0; for(long i=0;i<n;i++) s=(s+ps[i].x*ps[i].w+ps[i].y)%1000000007L;
  printf("%ld\n", s);
  return 0;
}
