#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <string.h>
static long run(const char *src,long n){ long ops[100000],jump[100000]; long len=0; for(long i=0;src[i];i++){ char b=src[i]; ops[len++]= b=='>'?0:b=='<'?1:b=='+'?2:b=='-'?3:b=='['?4:b==']'?5:6; }
  for(long i=0;i<len;i++) if(ops[i]==4){ long d=1,j=i+1; while(d>0){ if(ops[j]==4)d++; if(ops[j]==5)d--; if(d>0)j++; } jump[i]=j; jump[j]=i; }
  long tape[1000]={0}, pc=0,ptr=0,steps=0;
  while(pc<len){ long op=ops[pc];
    if(op==0)ptr++; if(op==1)ptr--; if(op==2)tape[ptr]=(tape[ptr]+1)%256; if(op==3)tape[ptr]=(tape[ptr]+255)%256;
    if(op==4&&tape[ptr]==0)pc=jump[pc]; if(op==5&&tape[ptr]!=0)pc=jump[pc]; pc++; steps++; }
  return steps*256+tape[3]; }
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 200;
  char *s=malloc(n+400); long k=0; for(long i=0;i<n;i++)s[k++]='+'; s[k++]='['; s[k++]='>'; for(int i=0;i<100;i++)s[k++]='+'; s[k++]='['; s[k++]='>'; for(int i=0;i<100;i++)s[k++]='+'; memcpy(s+k,"[>+<-]<-]<-]",12); k+=12; s[k]=0;
  printf("%ld\n", run(s,n));
  return 0;
}
