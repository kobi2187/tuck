module _28_async_task;

import rt = tuck_rt;

struct TRec_v(T_v) {
    T_v v;
}

struct TRec_r(T_r) {
    T_r r;
}

TRec_v!(long) tuckˑfnˑstepIo(long n) {
    return TRec_v!(long)(v: n);
}

TRec_r!(long) tuckˑtaskˑcompute(long base) {
    TRec_v!(long) tuckˑvˑa = tuckˑfnˑstepIo(base);
    TRec_v!(long) tuckˑvˑb = tuckˑfnˑstepIo(base);
    return TRec_r!(long)(r: (tuckˑvˑa.v + tuckˑvˑb.v));
}

long tuckˑfnˑmain() {
    auto tuckSlot1 = rt.newAsyncResult!(TRec_r!(long))();
    rt.spawnResult(tuckSlot1, { return tuckˑtaskˑcompute(21L); });
    TRec_r!(long) tuckˑvˑres = rt.awaitResult(tuckSlot1);
    return tuckˑvˑres.r;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    auto mainRc = tuckˑfnˑmain();
    rt.tuckRun();
    return cast(int) mainRc;
}
