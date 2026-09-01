module _28_async_task;

import rt = tuck_rt;

struct TRec_v_6D09 {
    long v;
}

struct TRec_r_4E67 {
    long r;
}

TRec_v_6D09 tuck_stepIo(long n) {
    return TRec_v_6D09(v: n);
}

TRec_r_4E67 tuck_compute(long base) {
    TRec_v_6D09 a = tuck_stepIo(base);
    TRec_v_6D09 b = tuck_stepIo(base);
    return TRec_r_4E67(r: (a.v + b.v));
}

long tuck_main() {
    auto tuckSlot1 = rt.newAsyncResult!(TRec_r_4E67)();
    rt.spawnResult(tuckSlot1, { return tuck_compute(21); });
    TRec_r_4E67 res = rt.awaitResult(tuckSlot1);
    return res.r;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    auto mainRc = tuck_main();
    rt.tuckRun();
    return cast(int) mainRc;
}
