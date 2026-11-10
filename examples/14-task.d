module _14_task;

import rt = tuck_rt;
import std.stdio : writeln, stderr;
import tuckˑmodˑhttp = mod_http;
import tuckˑmodˑshapes_14_task = mod_shapes_14_task;

struct tuckˑtypeˑFeed {
    long episodes;
}

tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed) tuckˑfnˑparse(T0)(T0 p0) {
    stderr.writeln("TUCK PENDING: parse invoked (not implemented)");
    return typeof(return).init;
}


struct TuckFˑtuckˑtaskˑfetchFeed
{
    rt.TuckFrameHdr tuckHdr;
    rt.TuckSlot!(rt.TuckResult!(tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed)))* tuckRes;
    rt.TuckResult!(tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed))* tuckDest;
    string url;
    rt.TuckResult!(tuckˑmodˑshapes_14_task.TRec_body!(string)) tuckˑvˑresp;
    bool tuckDefer0;
}

TuckFˑtuckˑtaskˑfetchFeed* TuckNewˑtuckˑtaskˑfetchFeed(TuckFˑtuckˑtaskˑfetchFeed* tuckAt, rt.TuckSlot!(rt.TuckResult!(tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed)))* tuckRes, rt.TuckResult!(tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed))* tuckDest, string url)
{
    auto f = tuckAt;
    if (f is null) f = new TuckFˑtuckˑtaskˑfetchFeed;
    else { *f = TuckFˑtuckˑtaskˑfetchFeed.init; f.tuckHdr.embedded = true; }
    f.tuckHdr.stage = &TuckSˑtuckˑtaskˑfetchFeedˑ0;
    f.tuckRes = tuckRes;
    f.tuckDest = tuckDest;
    f.url = url;
    return f;
}

rt.TuckHop TuckRetˑtuckˑtaskˑfetchFeed(TuckFˑtuckˑtaskˑfetchFeed* tuckF, rt.TuckResult!(tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed)) v)
{
    rt.tuckSlFinish(tuckF.tuckRes, tuckF.tuckDest, v);
    TuckExitˑtuckˑtaskˑfetchFeed(tuckF);
    return rt.tuckSlReturnHop(&tuckF.tuckHdr);
}

rt.TuckHop TuckSˑtuckˑtaskˑfetchFeedˑ0(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑfetchFeed*) env;
    with (*tuckF)
    {
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑfetchFeedˑ1);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑfetchFeedˑ1(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑfetchFeed*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑfetchFeedˑ2, &TuckIOˑtuckˑtaskˑfetchFeedˑ0);
    }
}

void TuckIOˑtuckˑtaskˑfetchFeedˑ0(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑfetchFeed*) env;
    with (*tuckF)
    {
        tuckˑvˑresp = tuckˑmodˑhttp.tuckˑfnˑget(url);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑfetchFeedˑ2(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑfetchFeed*) env;
    with (*tuckF)
    {
        tuckDefer0 = true;
        if ((tuckˑvˑresp.status == rt.TuckStatus.Ok)) {
            return TuckRetˑtuckˑtaskˑfetchFeed(tuckF, rt.tok(tuckˑfnˑparse(tuckˑvˑresp.value.body)));
        }
        return TuckRetˑtuckˑtaskˑfetchFeed(tuckF, rt.terr!(tuckˑmodˑshapes_14_task.TRec_feed!(tuckˑtypeˑFeed))(cast(ushort)(tuckˑvˑresp.err)));
    }
}

void TuckExitˑtuckˑtaskˑfetchFeed(TuckFˑtuckˑtaskˑfetchFeed* tuckF)
{
    with (*tuckF)
    {
        if (tuckDefer0)
        {
            rt.tuckDrop(tuckˑvˑresp);
            tuckDefer0 = false;
        }
    }
}
void TuckXˑtuckˑtaskˑfetchFeedˑ0(TuckFˑtuckˑtaskˑfetchFeed* tuckF)
{
    with (*tuckF)
    {
        if (tuckDefer0)
        {
            rt.tuckDrop(tuckˑvˑresp);
            tuckDefer0 = false;
        }
    }
}

