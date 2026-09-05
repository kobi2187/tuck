module _03_functions_bake;

import rt = tuck_rt;

struct TRec_a_b_2128 {
    long a;
    long b;
}

struct TRec_a_b_op_1096 {
    long a;
    long b;
    long function(long, long) op;
}

alias tuck_BinOp = long function(long a, long b);

long tuck_plus(long a, long b) {
    return (a + b);
}

long tuck_applyOperation(long a, long b, tuck_BinOp op) {
    return op(a, b);
}

void tuck_main() {
    TRec_a_b_2128 tuck_x = TRec_a_b_2128(a: 5, b: 10);
    TRec_a_b_op_1096 tuck_withOp = TRec_a_b_op_1096(a: tuck_x.a, b: tuck_x.b, op: &tuck_plus);
    TRec_a_b_op_1096 tuck_smaller = TRec_a_b_op_1096(a: tuck_withOp.a, b: 2, op: tuck_withOp.op);
    long tuck_r = tuck_applyOperation(tuck_smaller.a, tuck_smaller.b, tuck_smaller.op);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
