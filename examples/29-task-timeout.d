module _29_task_timeout;

import rt = tuck_rt;
import tuckˑmodˑshapes_29_task_timeout = mod_shapes_29_task_timeout;
import tuckˑmodˑtime = mod_time;

tuckˑmodˑshapes_29_task_timeout.TRec_fd!(long) openSource(long ms) {
    return rt.openSource!(tuckˑmodˑshapes_29_task_timeout.TRec_fd!(long))(ms);
}


struct TuckFˑtuckˑtaskˑreadOrGiveUp
{
    rt.TuckFrameHdr tuckHdr;
    rt.TuckSlot!(tuckˑmodˑshapes_29_task_timeout.TRec_code!(long))* tuckRes;
    tuckˑmodˑshapes_29_task_timeout.TRec_code!(long)* tuckDest;
    long fd;
    long tuckˑvˑcode;
}

TuckFˑtuckˑtaskˑreadOrGiveUp* TuckNewˑtuckˑtaskˑreadOrGiveUp(TuckFˑtuckˑtaskˑreadOrGiveUp* tuckAt, rt.TuckSlot!(tuckˑmodˑshapes_29_task_timeout.TRec_code!(long))* tuckRes, tuckˑmodˑshapes_29_task_timeout.TRec_code!(long)* tuckDest, long fd)
{
    auto f = tuckAt;
    if (f is null) f = new TuckFˑtuckˑtaskˑreadOrGiveUp;
    else { *f = TuckFˑtuckˑtaskˑreadOrGiveUp.init; f.tuckHdr.embedded = true; }
    f.tuckHdr.stage = &TuckSˑtuckˑtaskˑreadOrGiveUpˑ0;
    f.tuckRes = tuckRes;
    f.tuckDest = tuckDest;
    f.fd = fd;
    return f;
}

rt.TuckHop TuckRetˑtuckˑtaskˑreadOrGiveUp(TuckFˑtuckˑtaskˑreadOrGiveUp* tuckF, tuckˑmodˑshapes_29_task_timeout.TRec_code!(long) v)
{
    rt.tuckSlFinish(tuckF.tuckRes, tuckF.tuckDest, v);
    TuckExitˑtuckˑtaskˑreadOrGiveUp(tuckF);
    return rt.tuckSlReturnHop(&tuckF.tuckHdr);
}

rt.TuckHop TuckSˑtuckˑtaskˑreadOrGiveUpˑ0(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑreadOrGiveUp*) env;
    with (*tuckF)
    {
        tuckˑvˑcode = 0L;
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑreadOrGiveUpˑ1, &TuckIOˑtuckˑtaskˑreadOrGiveUpˑ0);
    }
}

void TuckIOˑtuckˑtaskˑreadOrGiveUpˑ0(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑreadOrGiveUp*) env;
    with (*tuckF)
    {
        if (rt.tuckAwaitReadOrTimeout(fd, tuckˑmodˑtime.tuckˑfnˑms(cast(uint)30))) {
            tuckˑvˑcode = 1L;
        } else {
            tuckˑvˑcode = 2L;
        }
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑreadOrGiveUpˑ1(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑreadOrGiveUp*) env;
    with (*tuckF)
    {
        return TuckRetˑtuckˑtaskˑreadOrGiveUp(tuckF, tuckˑmodˑshapes_29_task_timeout.TRec_code!(long)(code: tuckˑvˑcode));
    }
}

void TuckExitˑtuckˑtaskˑreadOrGiveUp(TuckFˑtuckˑtaskˑreadOrGiveUp* tuckF)
{
    with (*tuckF)
    {
    }
}

long tuckˑfnˑmain() {
    tuckˑmodˑshapes_29_task_timeout.TRec_fd!(long) tuckˑvˑsrc = openSource(500L);
    rt.TuckSlot!(tuckˑmodˑshapes_29_task_timeout.TRec_code!(long)) tuckSlot1;
    TuckFˑtuckˑtaskˑreadOrGiveUp tuckSlot1F;
    rt.tuckSlReady(&TuckNewˑtuckˑtaskˑreadOrGiveUp(&tuckSlot1F, &tuckSlot1, null, tuckˑvˑsrc.fd).tuckHdr);
    tuckˑmodˑshapes_29_task_timeout.TRec_code!(long) tuckˑvˑr = rt.tuckSlAwaitMain(&tuckSlot1);
    return tuckˑvˑr.code;
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
