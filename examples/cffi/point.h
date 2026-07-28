/* Tiny C library for the FFI examples. Deliberately minimal, and hand-diffable:
   it covers exactly the four things a real C API makes Tuck prove — a struct
   passed and returned by value, an enum with EXPLICIT values, and a function
   pointer the C side calls back into. */
#ifndef TUCK_EXAMPLE_POINT_H
#define TUCK_EXAMPLE_POINT_H

typedef struct { int x; int y; } Point;

/* returns x*100 + y — an answer no wrong binding produces by accident */
int takesPoint(Point p);
Point makesPoint(int x, int y);

/* Explicit, non-sequential values: the common shape in real headers, and the
   case a 0,1,2.. enum would silently get wrong. */
typedef enum { OP_ADD = 10, OP_MUL = 20, OP_NEG = 30 } Op;

/* applies Op to a and b, so a mis-numbered enum returns the wrong answer */
int applyOp(Op op, int a, int b);

/* C calls back into Tuck: returns cb(a, b) + 1000 */
typedef int (*BinOp)(int a, int b);
int callBack(BinOp cb, int a, int b);

#endif
