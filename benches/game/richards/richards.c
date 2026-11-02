#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <string.h>
typedef struct Pk{struct Pk *link; long id,kind,a1,a2[4];}Pk;
typedef struct Tcb Tcb;
typedef struct{ long queued,held,curId; Tcb *cur; Tcb *list; Tcb *blocks[6]; }Sch;
struct Tcb{ Tcb *link; long id,pri,state,kind,v1,v2; Pk *queue; Pk *pv1,*pv2; };
static Pk *addTo(Pk *p,Pk *q){ p->link=0; if(!q)return p; Pk *n=q; while(n->link)n=n->link; n->link=p; return q; }
static Tcb *release(Sch *s,long id){ Tcb *t=s->blocks[id]; if(t->state>=4)t->state-=4; return t->pri>s->cur->pri? t : s->cur; }
static Tcb *hold(Sch *s){ s->held++; if(s->cur->state<4)s->cur->state+=4; return s->cur->link; }
static Tcb *susp(Sch *s){ if(s->cur->state%4<2)s->cur->state+=2; return s->cur; }
static Tcb *queue(Sch *s,Pk *p){ Tcb *t=s->blocks[p->id]; s->queued++; p->link=0; p->id=s->curId;
  if(!t->queue){ t->queue=p; if(t->state%2==0)t->state++; if(t->pri>s->cur->pri)return t; } else t->queue=addTo(p,t->queue); return s->cur; }
static Tcb *runTask(Sch *s,Tcb *t,Pk *p){
  switch(t->kind){
  case 0: { t->v2--; if(t->v2==0)return hold(s); if(t->v1%2==0){ t->v1/=2; return release(s,4);} t->v1=(t->v1/2)^0xD008; return release(s,5); }
  case 1: { if(!p)return susp(s); t->v1= t->v1==2?3:2; p->id=t->v1; p->a1=0; for(int i=0;i<4;i++){ t->v2++; if(t->v2>26)t->v2=1; p->a2[i]=t->v2; } return queue(s,p); }
  case 2: { if(p){ if(p->kind==1)t->pv1=addTo(p,t->pv1); else t->pv2=addTo(p,t->pv2); }
    if(t->pv1){ long c=t->pv1->a1; if(c<4){ if(t->pv2){ Pk *v=t->pv2; t->pv2=v->link; v->a1=t->pv1->a2[c]; t->pv1->a1=c+1; return queue(s,v);} } else { Pk *v=t->pv1; t->pv1=v->link; return queue(s,v);} } return susp(s); }
  default: { if(!p){ if(!t->pv1)return susp(s); Pk *v=t->pv1; t->pv1=0; return queue(s,v);} t->pv1=p; return hold(s); } } }
static Tcb *mk(Sch *s,long id,long pri,Pk *q,long kind,long v1,long v2){ Tcb *t=calloc(1,sizeof(Tcb)); t->link=s->list; t->id=id;t->pri=pri;t->queue=q;t->state=q?3:2;t->kind=kind;t->v1=v1;t->v2=v2; s->list=t; s->blocks[id]=t; s->cur=t; return t; }
static Pk *pk(Pk *link,long id,long kind){ Pk *p=calloc(1,sizeof(Pk)); p->link=link;p->id=id;p->kind=kind; return p; }
static long bench(long count){ Sch s; memset(&s,0,sizeof s);
  Tcb *idle=mk(&s,0,0,0,0,1,count); idle->state=0;
  Pk *q=pk(0,1,1); q=pk(q,1,1); Tcb *w=mk(&s,1,1000,q,1,2,0); (void)w;
  q=0; for(int i=0;i<3;i++)q=pk(q,4,0); Tcb *ha=mk(&s,2,2000,q,2,0,0); ha->pv1=0; ha->pv2=0;
  q=0; for(int i=0;i<3;i++)q=pk(q,5,0); Tcb *hb=mk(&s,3,3000,q,2,0,0); hb->pv1=0; hb->pv2=0;
  mk(&s,4,4000,0,3,0,0); mk(&s,5,5000,0,3,0,0);
  Tcb *cur=s.list;
  while(cur){ if(cur->state>=4||cur->state==2) cur=cur->link; else { s.cur=cur; s.curId=cur->id; Pk *p=0;
      if(cur->state==3){ p=cur->queue; cur->queue=p->link; cur->state= cur->queue?1:0; }
      cur=runTask(&s,cur,p); } }
  return s.queued*100000+s.held; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  long total=0; for(long i=0;i<n;i++) total+=bench(1000); printf("%ld\n", total);
  return 0;
}
