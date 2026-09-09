module _03_functions_bake;

import rt = tuck_rt;

struct TRec_a_b_op_5F99 {
    long a;
    long b;
    tuck_BinOp op;
}

alias tuck_BinOp = long function(long a, long b);

struct tuck_Ctx {
    long a;
    long b;
    tuck_BinOp op;
}

long tuck_plus(long a, long b) {
    return (a + b);
}

long tuck_applyOperation(long a, long b, tuck_BinOp op) {
    return op(a, b);
}

void tuck_main() {
    tuck_Ctx tuck_x = tuck_Ctx(a: 5L, b: 10L);
    TRec_a_b_op_5F99 tuck_withOp = TRec_a_b_op_5F99(a: tuck_x.a, b: tuck_x.b, op: &tuck_plus);
    TRec_a_b_op_5F99 tuck_smaller = TRec_a_b_op_5F99(a: tuck_withOp.a, b: 2L, op: tuck_withOp.op);
    long tuck_r = tuck_applyOperation(tuck_smaller.a, tuck_smaller.b, tuck_smaller.op);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
