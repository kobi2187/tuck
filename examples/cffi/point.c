#include "point.h"

int takesPoint(Point p) { return p.x * 100 + p.y; }

Point makesPoint(int x, int y) {
	Point r;
	r.x = x;
	r.y = y;
	return r;
}
