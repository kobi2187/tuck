/* Tiny C library for examples/35-ffi-struct.tuck — the struct-by-value FFI
   check. Deliberately minimal: one typedef'd struct, one function taking it by
   value, one returning it by value. That is the whole ABI surface the test
   needs, and it stays diffable by hand. */
#ifndef TUCK_EXAMPLE_POINT_H
#define TUCK_EXAMPLE_POINT_H

typedef struct { int x; int y; } Point;

/* returns x*100 + y — an answer no wrong binding produces by accident */
int takesPoint(Point p);
Point makesPoint(int x, int y);

#endif
