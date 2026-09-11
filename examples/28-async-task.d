module _28_async_task;

import rt = tuck_rt;

struct TRec_v(T_v) {
    T_v v;
}

struct TRec_r(T_r) {
    T_r r;
}

TRec_v!(long) tuck_stepIo(long n) {
    return TRec_v!(long)(v: n);
}

TRec_r!(long) tuck_compute(long base) {
    TRec_v!(long) tuck_a = tuck_stepIo(base);
    TRec_v!(long) tuck_b = tuck_stepIo(base);
    return TRec_r!(long)(r: (tuck_a.v + tuck_b.v));
}

long tuck_main() {
    auto tuckSlot1 = rt.newAsyncResult!(TRec_r!(long))();
    rt.spawnResult(tuckSlot1, { return tuck_compute(21L); });
    TRec_r!(long) tuck_res = rt.awaitResult(tuckSlot1);
    return tuck_res.r;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    auto mainRc = tuck_main();
    rt.tuckRun();
    return cast(int) mainRc;
}
