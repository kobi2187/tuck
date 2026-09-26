module _03_functions_bake;

import rt = tuck_rt;

struct TRec_a_b_op(T_a, T_b, T_op) {
    T_a a;
    T_b b;
    T_op op;
}

alias tuckˑfnsigˑBinOp = long function(long a, long b);

struct tuckˑtypeˑCtx {
    long a;
    long b;
    tuckˑfnsigˑBinOp op;
}

long tuckˑfnˑplus(long a, long b) {
    return (a + b);
}

long tuckˑfnˑapplyOperation(long a, long b, tuckˑfnsigˑBinOp op) {
    return op(a, b);
}

void tuckˑfnˑmain() {
    tuckˑtypeˑCtx tuckˑvˑx = tuckˑtypeˑCtx(a: 5L, b: 10L);
    TRec_a_b_op!(long, long, tuckˑfnsigˑBinOp) tuckˑvˑwithOp = TRec_a_b_op!(long, long, tuckˑfnsigˑBinOp)(a: tuckˑvˑx.a, b: tuckˑvˑx.b, op: &tuckˑfnˑplus);
    TRec_a_b_op!(long, long, tuckˑfnsigˑBinOp) tuckˑvˑsmaller = TRec_a_b_op!(long, long, tuckˑfnsigˑBinOp)(a: tuckˑvˑwithOp.a, b: 2L, op: tuckˑvˑwithOp.op);
    long tuckˑvˑr = tuckˑfnˑapplyOperation(tuckˑvˑsmaller.a, tuckˑvˑsmaller.b, tuckˑvˑsmaller.op);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
