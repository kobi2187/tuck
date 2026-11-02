#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
typedef struct J{int k; long v; char *s; long n; struct J **items; char **keys;} J;
static const char *T; static long P;
static void ws(void){ while(T[P]==' ')P++; }
static char *ptext(void){ long st=++P; while(T[P]!='"')P++; char *s=malloc(P-st+1); memcpy(s,T+st,P-st); s[P-st]=0; P++; return s; }
static J *pv(void);
static J *mk(int k){ J *j=calloc(1,sizeof(J)); j->k=k; return j; }
static J *pv(void){ ws(); char b=T[P];
  if(b=='{'){ P++; J *o=mk(4); long cap=4; o->items=malloc(cap*sizeof(J*)); o->keys=malloc(cap*sizeof(char*)); ws(); if(T[P]=='}'){P++;return o;}
    for(;;){ ws(); char *k=ptext(); ws(); P++; J *v=pv(); if(o->n==cap){cap*=2;o->items=realloc(o->items,cap*sizeof(J*));o->keys=realloc(o->keys,cap*sizeof(char*));} o->keys[o->n]=k;o->items[o->n++]=v; ws(); if(T[P]==','){P++;continue;} break; } P++; return o; }
  if(b=='['){ P++; J *a=mk(3); long cap=4; a->items=malloc(cap*sizeof(J*)); ws(); if(T[P]==']'){P++;return a;}
    for(;;){ J *v=pv(); if(a->n==cap){cap*=2;a->items=realloc(a->items,cap*sizeof(J*));} a->items[a->n++]=v; ws(); if(T[P]==','){P++;continue;} break; } P++; return a; }
  if(b=='"'){ J *t=mk(2); t->s=ptext(); return t; }
  if(b=='n'){ P+=4; return mk(0); }
  J *nm=mk(1); long v=0; while(T[P]>='0'&&T[P]<='9'){v=v*10+(T[P]-'0');P++;} nm->v=v; return nm; }
static long fold(J *j){ long s=0; switch(j->k){ case 1: return j->v; case 2: return strlen(j->s); case 3: for(long i=0;i<j->n;i++)s+=fold(j->items[i]); return s; case 4: for(long i=0;i<j->n;i++)s+=strlen(j->keys[i])+fold(j->items[i]); return s; } return 0; }
static long rlen(J *j){ char tmp[32]; long s=0; switch(j->k){ case 0: return 4; case 1: return sprintf(tmp,"%ld",j->v); case 2: return strlen(j->s)+2;
  case 3: s=2; for(long i=0;i<j->n;i++){ if(i)s++; s+=rlen(j->items[i]); } return s;
  case 4: s=2; for(long i=0;i<j->n;i++){ if(i)s++; s+=strlen(j->keys[i])+3+rlen(j->items[i]); } return s; } return 0; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  size_t cap=n*80+16,len=0; char *d=malloc(cap); d[len++]='['; char tmp[160];
  for(long i=0;i<n;i++){ if(i){d[len++]=',';d[len++]=' ';} len+=sprintf(d+len,"{\"id\": %ld, \"name\": \"item%ld\", \"tags\": [\"a\", \"bb\", null], \"score\": %ld}",i,i,i*7%100); }
  d[len++]=']'; d[len]=0; (void)tmp; T=d; P=0; J *root=pv();
  printf("%ld\n", fold(root)*1000003+rlen(root));
  return 0;
}
