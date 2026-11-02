#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef struct{long *start,*adj;}Csr;
static long *EF,*ET; static long NE=0, NV=1;
static void edge(long a,long b){ EF[NE]=a; ET[NE]=b; NE++; }
static long newNode(void){ return NV++; }
static long diamond(long entry){ long a=newNode(); long b=newNode(); long j=newNode(); edge(entry,a);edge(entry,b);edge(a,j);edge(b,j); return j; }
static long loopRegion(long entry,long depth){ long h=newNode(); edge(entry,h); long cur=diamond(h);
  if(depth>0){ cur=loopRegion(cur,depth-1); cur=loopRegion(cur,depth-1);} edge(cur,h); long x=newNode(); edge(h,x); return x; }
static Csr adjacency(long n,long *key,long *other,long m){ Csr c; c.start=calloc(n+1,sizeof(long)); c.adj=calloc(m?m:1,sizeof(long));
  for(long i=0;i<m;i++)c.start[key[i]+1]++; for(long i=0;i<n;i++)c.start[i+1]+=c.start[i];
  long *fill=malloc(n*sizeof(long)); for(long i=0;i<n;i++)fill[i]=c.start[i];
  for(long i=0;i<m;i++){ long k=key[i]; c.adj[fill[k]++]=other[i]; } free(fill); return c; }
static long find(long *parent,long x){ long r=x; while(parent[r]!=r)r=parent[r]; return r; }
static inline int anc(long w,long v,long *last){ return w<=v && v<=last[w]; }
static long analyze(long regions){ NE=0; NV=1; long cap=regions*220+16; EF=malloc(cap*sizeof(long)); ET=malloc(cap*sizeof(long));
  long cur=0; for(long i=0;i<regions;i++) cur=loopRegion(cur,4);
  long n=NV; Csr succ=adjacency(n,EF,ET,NE), preds=adjacency(n,ET,EF,NE);
  long *number=malloc(n*sizeof(long)),*last=calloc(n,sizeof(long)),*cursor=malloc(n*sizeof(long)),*dstack=calloc(n,sizeof(long)),*nodes=malloc(n*sizeof(long));
  for(long i=0;i<n;i++){number[i]=-1;cursor[i]=succ.start[i];}
  long nn=1,sp=1,counter=1; nodes[0]=0; number[0]=0;
  while(sp>0){ long top=dstack[sp-1]; if(cursor[top]<succ.start[top+1]){ long s=succ.adj[cursor[top]++]; if(number[s]<0){ number[s]=counter; nodes[nn++]=s; counter++; dstack[sp++]=s; } } else { last[number[top]]=counter-1; sp--; } }
  long size=nn; long *parent=malloc(size*sizeof(long)),*header=calloc(size,sizeof(long)),*stamp=malloc(size*sizeof(long));
  for(long i=0;i<size;i++){parent[i]=i;stamp[i]=-1;}
  long *pool=malloc(n*sizeof(long)); long *work=malloc(n*sizeof(long)); long found=0,irr=0;
  for(long w=size-1;w>=0;w--){ long np=0,nw=0,node=nodes[w],kind=0;
    for(long k=preds.start[node];k<preds.start[node+1];k++){ long v=number[preds.adj[k]]; if(v>=0&&anc(w,v,last)){ if(v!=w){ long r=find(parent,v); pool[np++]=r; stamp[r]=w; } else kind=2; } }
    if(np>0)kind=1;
    for(long i=0;i<np;i++)work[nw++]=pool[i];
    for(long qi=0;qi<nw;qi++){ long x=work[qi]; long xn=nodes[x];
      for(long k=preds.start[xn];k<preds.start[xn+1];k++){ long y=number[preds.adj[k]]; if(y>=0&&!anc(x,y,last)){ long yd=find(parent,y);
        if(!anc(w,yd,last))kind=3; else if(yd!=w&&stamp[yd]!=w){ work[nw++]=yd; pool[np++]=yd; stamp[yd]=w; } } } }
    if(np>0||kind==2){ found++; if(kind==3)irr++; for(long i=0;i<np;i++){ header[pool[i]]=w; parent[pool[i]]=w; } } }
  long sum=0; for(long i=0;i<size;i++)sum=(sum+header[i])%1000000007L;
  return found*1000003+irr*1009+sum; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 100;
  printf("%ld\n", analyze(n));
  return 0;
}
