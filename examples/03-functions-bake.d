module _03_functions_bake;

import rt = tuck_rt;

struct TRec_a_b_op(T_a, T_b, T_op) {
    T_a a;
    T_b b;
    T_op op;
}

alias tuck_type_BinOp = long function(long a, long b);

struct tuck_type_Ctx {
    long a;
    long b;
    tuck_type_BinOp op;
}

long tuck_fn_plus(long a, long b) {
    return (a + b);
}

long tuck_fn_applyOperation(long a, long b, tuck_type_BinOp op) {
    return op(a, b);
}

void tuck_fn_main() {
    tuck_type_Ctx tuck_x = tuck_type_Ctx(a: 5L, b: 10L);
    TRec_a_b_op!(long, long, tuck_type_BinOp) tuck_withOp = TRec_a_b_op!(long, long, tuck_type_BinOp)(a: tuck_x.a, b: tuck_x.b, op: &tuck_fn_plus);
    TRec_a_b_op!(long, long, tuck_type_BinOp) tuck_smaller = TRec_a_b_op!(long, long, tuck_type_BinOp)(a: tuck_withOp.a, b: 2L, op: tuck_withOp.op);
    long tuck_r = tuck_fn_applyOperation(tuck_smaller.a, tuck_smaller.b, tuck_smaller.op);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
