#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define IM 139968
#define IA 3877
#define IC 29573
static long count(const char *pat, const char *s, long n) {
  regex_t re; regcomp(&re, pat, REG_EXTENDED);
  long c = 0, at = 0; regmatch_t m[1];
  while (at <= n) {
    m[0].rm_so = at; m[0].rm_eo = n;
    if (regexec(&re, s, 1, m, REG_STARTEND) != 0) break;
    c++; at = m[0].rm_eo > m[0].rm_so ? m[0].rm_eo : m[0].rm_eo + 1;
  }
  regfree(&re); return c;
}
static char *rewrite(const char *pat, const char *with, const char *s, long n, long *outn) {
  regex_t re; regcomp(&re, pat, REG_EXTENDED);
  char *out = malloc(n * 2 + 16); long o = 0, at = 0, wl = strlen(with); regmatch_t m[1];
  while (at <= n) {
    m[0].rm_so = at; m[0].rm_eo = n;
    if (regexec(&re, s, 1, m, REG_STARTEND) != 0) break;
    long so = m[0].rm_so, eo = m[0].rm_eo;
    if (eo == so) { if (so < n) out[o++] = s[so]; memcpy(out + o - 0, "", 0); at = so + 1; continue; }
    memcpy(out + o, s + at, so - at); o += so - at;
    memcpy(out + o, with, wl); o += wl; at = eo;
  }
  if (at < n) { memcpy(out + o, s + at, n - at); o += n - at; }
  out[o] = 0; regfree(&re); *outn = o; return out;
}
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 1000;
  const char *codes = "acgtBDHKMNRSVWY";
  char *raw = malloc(n + n / 60 + 64); long r = 0, seed = 42;
  const char *head = ">ONE Homo sapiens alu\n"; memcpy(raw, head, strlen(head)); r = strlen(head);
  for (long i = 0; i < n; i++) {
    seed = (seed * IA + IC) % IM; { int at; if (seed % 20 == 0) at = 4 + (seed / 20) % 11; else { double q = (double)seed / IM;
      at = q < 0.3029549426680 ? 0 : q < 0.5009432431601 ? 1 : q < 0.6984905497992 ? 2 : 3; } raw[r++] = codes[at]; }
    if ((i + 1) % 60 == 0 || i + 1 == n) raw[r++] = '\n';
  }
  raw[r] = 0; long sn;
  char *st = rewrite(">[^\n]*\n|\n", "", raw, r, &sn);
  const char *v[] = {"agggtaaa|tttaccct","[cgt]gggtaaa|tttaccc[acg]","a[act]ggtaaa|tttacc[agt]t",
    "ag[act]gtaaa|tttac[agt]ct","agg[act]taaa|ttta[agt]cct","aggg[acg]aaa|ttt[cgt]ccct",
    "agggt[cgt]aa|tt[acg]accct","agggta[cgt]a|t[acg]taccct","agggtaa[cgt]|[acg]ttaccct"};
  for (int i = 0; i < 9; i++) printf("%s %ld\n", v[i], count(v[i], st, sn));
  long fn; char *s = st; long cn = sn;
  const char *pats[] = {"tHa[Nt]","aND|caN|Ha[DS]|WaS","a[NSt]|BY","<[^>]*>","\\|[^|][^|]*\\|"};
  const char *with[] = {"<4>","<3>","<2>","|","-"};
  for (int i = 0; i < 5; i++) { s = rewrite(pats[i], with[i], s, cn, &fn); cn = fn; }
  printf("\n%ld\n%ld\n%ld\n", r, sn, cn);
  return 0;
}
