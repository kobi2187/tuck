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

struct TuckFˑtuckˑtaskˑcompute
{
    rt.TuckFrameHdr tuckHdr;
    rt.TuckSlot!(TRec_r!(long))* tuckRes;
    TRec_r!(long)* tuckDest;
    long base;
    TRec_v!(long) tuckˑvˑa;
    TRec_v!(long) tuckˑvˑb;
}

TuckFˑtuckˑtaskˑcompute* TuckNewˑtuckˑtaskˑcompute(rt.TuckSlot!(TRec_r!(long))* tuckRes, TRec_r!(long)* tuckDest, long base)
{
    auto f = new TuckFˑtuckˑtaskˑcompute;
    f.tuckHdr.stage = &TuckSˑtuckˑtaskˑcomputeˑ0;
    f.tuckRes = tuckRes;
    f.tuckDest = tuckDest;
    f.base = base;
    return f;
}

rt.TuckHop TuckRetˑtuckˑtaskˑcompute(TuckFˑtuckˑtaskˑcompute* tuckF, TRec_r!(long) v)
{
    rt.tuckSlFinish(tuckF.tuckRes, tuckF.tuckDest, v);
    TuckExitˑtuckˑtaskˑcompute(tuckF);
    return rt.tuckSlReturnHop(&tuckF.tuckHdr);
}

rt.TuckHop TuckSˑtuckˑtaskˑcomputeˑ0(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑcompute*) env;
    with (*tuckF)
    {
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑcomputeˑ1);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑcomputeˑ1(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑcompute*) env;
    with (*tuckF)
    {
        tuckˑvˑa = tuckˑfnˑstepIo(base);
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑcomputeˑ2);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑcomputeˑ2(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑcompute*) env;
    with (*tuckF)
    {
        tuckˑvˑb = tuckˑfnˑstepIo(base);
        return TuckRetˑtuckˑtaskˑcompute(tuckF, TRec_r!(long)(r: (tuckˑvˑa.v + tuckˑvˑb.v)));
    }
}

void TuckExitˑtuckˑtaskˑcompute(TuckFˑtuckˑtaskˑcompute* tuckF)
{
    with (*tuckF)
    {
    }
}

long tuckˑfnˑmain() {
    rt.TuckSlot!(TRec_r!(long)) tuckSlot1;
    rt.tuckSlReady(&TuckNewˑtuckˑtaskˑcompute(&tuckSlot1, null, 21L).tuckHdr);
    TRec_r!(long) tuckˑvˑres = rt.tuckSlAwaitMain(&tuckSlot1);
    return tuckˑvˑres.r;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    rt.tuckLeakMark();
    auto mainRc = tuckˑfnˑmain();
    rt.tuckSlRunAll();
    rt.tuckRun();
    return rt.tuckLeakCheck(cast(int) mainRc);
}
