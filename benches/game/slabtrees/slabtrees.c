/* binary-trees reference: the same algorithm as binarytrees.tuck, plain C with malloc/free. */
#include <stdio.h>
#include <stdlib.h>
typedef struct Node { struct Node *l, *r; } Node;
static Node *bottomUp(int d) {
  Node *n = malloc(sizeof *n);
  if (d == 0) { n->l = n->r = NULL; return n; }
  n->l = bottomUp(d - 1); n->r = bottomUp(d - 1); return n;
}
static int check(Node *n) { return n->l ? 1 + check(n->l) + check(n->r) : 1; }
static void drop(Node *n) { if (n->l) { drop(n->l); drop(n->r); } free(n); }
int main(int argc, char **argv) {
  int n = argc > 1 ? atoi(argv[1]) : 10, max = n < 6 ? 6 : n;
  Node *s = bottomUp(max + 1); printf("stretch tree of depth %d\t check: %d\n", max + 1, check(s)); drop(s);
  Node *ll = bottomUp(max);
  for (int d = 4; d <= max; d += 2) {
    int it = 1 << (max - d + 4), t = 0;
    for (int i = 0; i < it; i++) { Node *x = bottomUp(d); t += check(x); drop(x); }
    printf("%d\t trees of depth %d\t check: %d\n", it, d, t);
  }
  printf("long lived tree of depth %d\t check: %d\n", max, check(ll)); drop(ll);
  return 0;
}
