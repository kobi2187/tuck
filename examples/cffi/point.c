#include "point.h"

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
