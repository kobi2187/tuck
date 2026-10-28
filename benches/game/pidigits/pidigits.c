#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef long long ll;
#define BASE 1000000000LL
typedef struct { ll *d; int n, cap; } Nat;
static Nat mk(int cap) { Nat a; a.d = malloc(sizeof(ll) * (cap + 2)); a.n = 0; a.cap = cap + 2; return a; }
static Nat from(ll v) { Nat a = mk(2); if (v > 0) a.d[a.n++] = v; return a; }
static Nat mul(Nat a, ll m) {
  Nat o = mk(a.n + 1); if (m == 0) return o; ll c = 0;
  for (int i = 0; i < a.n; i++) { ll x = a.d[i] * m + c; o.d[o.n++] = x % BASE; c = x / BASE; }
  if (c > 0) o.d[o.n++] = c; return o;
}
static Nat add(Nat a, Nat b) {
  int n = a.n > b.n ? a.n : b.n; Nat o = mk(n + 1); ll c = 0;
  for (int i = 0; i < n; i++) { ll x = c + (i < a.n ? a.d[i] : 0) + (i < b.n ? b.d[i] : 0); o.d[o.n++] = x % BASE; c = x / BASE; }
  if (c > 0) o.d[o.n++] = c; return o;
}
static Nat sub(Nat a, Nat b) {
  Nat o = mk(a.n); ll br = 0;
  for (int i = 0; i < a.n; i++) { ll x = a.d[i] - br - (i < b.n ? b.d[i] : 0); br = 0; if (x < 0) { x += BASE; br = 1; } o.d[o.n++] = x; }
  while (o.n > 0 && o.d[o.n - 1] == 0) o.n--; return o;
}
static int cmp(Nat a, Nat b) {
  if (a.n != b.n) return a.n < b.n ? -1 : 1;
  for (int i = a.n - 1; i >= 0; i--) if (a.d[i] != b.d[i]) return a.d[i] < b.d[i] ? -1 : 1;
  return 0;
}
static int quotient(Nat a, Nat b) {
  Nat r = a; int q = 0; int own = 0;
  while (cmp(r, b) >= 0) { Nat t = sub(r, b); if (own) free(r.d); r = t; own = 1; q++; }
  if (own) free(r.d); return q;
}
int main(int argc, char **argv) {
  long n = argc > 1 ? atol(argv[1]) : 27, shown = 0;
  Nat numer = from(1), denom = from(1), accum = from(0); ll k = 0; char line[16]; int ll_ = 0;
  while (shown < n) {
    k++; ll y2 = k * 2 + 1;
    Nat dbl = mul(numer, 2), sum = add(accum, dbl), na = mul(sum, y2), nn = mul(numer, k), nd = mul(denom, y2);
    free(dbl.d); free(sum.d); free(accum.d); free(numer.d); free(denom.d);
    accum = na; numer = nn; denom = nd;
    if (cmp(numer, accum) > 0) continue;
    Nat s3 = mul(numer, 3), t3 = add(s3, accum); int d = quotient(t3, denom);
    Nat s4 = mul(numer, 4), t4 = add(s4, accum); int e = quotient(t4, denom);
    free(s3.d); free(t3.d); free(s4.d); free(t4.d);
    if (d != e) continue;
    line[ll_++] = '0' + d; shown++;
    if (shown % 10 == 0 || shown == n) { line[ll_] = 0; printf("%-10s\t:%ld\n", line, shown); ll_ = 0; }
    Nat tk = mul(denom, d), rest = sub(accum, tk), a2 = mul(rest, 10), n2 = mul(numer, 10);
    free(tk.d); free(rest.d); free(accum.d); free(numer.d); accum = a2; numer = n2;
  }
  return 0;
}
