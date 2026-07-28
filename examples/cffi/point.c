#include "point.h"
#include <stdlib.h>

int takesPoint(Point p) { return p.x * 100 + p.y; }

Point makesPoint(int x, int y) {
	Point r;
	r.x = x;
	r.y = y;
	return r;
}

int applyOp(Op op, int a, int b) {
	switch (op) {
		case OP_ADD: return a + b;
		case OP_MUL: return a * b;
		case OP_NEG: return -a;
		default: return -999;   /* a wrong enum value lands here */
	}
}

int callBack(BinOp cb, int a, int b) { return cb(a, b) + 1000; }

/* the definition lives here, not in the header — that is what makes it opaque */
struct Counter { int total; };

Counter *counterNew(int start) {
	Counter *c = malloc(sizeof(Counter));
	c->total = start;
	return c;
}

int counterBump(Counter *c, int by) {
	c->total += by;
	return c->total;
}

void counterFree(Counter *c) { free(c); }
