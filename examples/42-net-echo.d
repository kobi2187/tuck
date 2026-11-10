module _42_net_echo;

import rt = tuck_rt;
import tuckˑmodˑnet = mod_net;
import tuckˑmodˑscheduler = mod_scheduler;
import tuckˑmodˑshapes_42_net_echo = mod_shapes_42_net_echo;

enum tuckˑactorˑResultMsgKind { msgPut }

struct tuckˑactorˑResultMsg {
    tuckˑactorˑResultMsgKind tuckTag;
    long c;
}

struct tuckˑactorˑResult {
    long code;
    bool ready;
    rt.Mailbox!(tuckˑactorˑResultMsg, 8) mailbox;
}

__gshared tuckˑactorˑResult tuckˑactorˑResultSingleton;

shared static this() {
    tuckˑactorˑResultSingleton.code = 0L;
    tuckˑactorˑResultSingleton.ready = false;
}

void handleMsg_tuckˑactorˑResult(ref tuckˑactorˑResult self, tuckˑactorˑResultMsg msg) {
    final switch (msg.tuckTag) {
        case tuckˑactorˑResultMsgKind.msgPut:
            auto c = msg.c;
            self.code = c;
            self.ready = true;
            break;
    }
}

__gshared void* tuckˑactorˑResultSlot;

bool drain_tuckˑactorˑResult() {
    bool did = false;
    foreach (ref msg; tuckˑactorˑResultSingleton.mailbox) {
        handleMsg_tuckˑactorˑResult(tuckˑactorˑResultSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendPut_tuckˑactorˑResult(ref tuckˑactorˑResult self, long c) {
    rt.sendWaiting(self.mailbox, tuckˑactorˑResultMsg(tuckTag: tuckˑactorˑResultMsgKind.msgPut, c: c), tuckˑactorˑResultSlot, "Result");
    rt.tuckNotifySend(tuckˑactorˑResultSlot);
}


struct TuckFˑtuckˑtaskˑserve
{
    rt.TuckFrameHdr tuckHdr;
    rt.TuckSlot!(bool)* tuckRes;
    bool* tuckDest;
    long lfd;
    rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)) tuckˑvˑc;
    rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_data!(string)) tuckOwnTmp1;
    bool tuckDefer0;
}

TuckFˑtuckˑtaskˑserve* TuckNewˑtuckˑtaskˑserve(TuckFˑtuckˑtaskˑserve* tuckAt, rt.TuckSlot!(bool)* tuckRes, bool* tuckDest, long lfd)
{
    auto f = tuckAt;
    if (f is null) f = new TuckFˑtuckˑtaskˑserve;
    else { *f = TuckFˑtuckˑtaskˑserve.init; f.tuckHdr.embedded = true; }
    f.tuckHdr.stage = &TuckSˑtuckˑtaskˑserveˑ0;
    f.tuckRes = tuckRes;
    f.tuckDest = tuckDest;
    f.lfd = lfd;
    return f;
}

rt.TuckHop TuckRetˑtuckˑtaskˑserve(TuckFˑtuckˑtaskˑserve* tuckF)
{
    if (tuckF.tuckRes !is null) rt.tuckSlComplete(tuckF.tuckRes, true);
    TuckExitˑtuckˑtaskˑserve(tuckF);
    return rt.tuckSlReturnHop(&tuckF.tuckHdr);
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ0(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑserveˑ1);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ1(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑserveˑ2, &TuckIOˑtuckˑtaskˑserveˑ0);
    }
}

void TuckIOˑtuckˑtaskˑserveˑ0(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        tuckˑvˑc = tuckˑmodˑnet.accept(lfd);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ2(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        if ((tuckˑvˑc.status == rt.TuckStatus.Ok)) return TuckSˑtuckˑtaskˑserveˑ4(env);
        return TuckSˑtuckˑtaskˑserveˑ11(env);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ3(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        return TuckRetˑtuckˑtaskˑserve(tuckF);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ4(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑserveˑ5);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ5(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑserveˑ6, &TuckIOˑtuckˑtaskˑserveˑ1);
    }
}

void TuckIOˑtuckˑtaskˑserveˑ1(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        tuckOwnTmp1 = tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256L);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ6(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        tuckDefer0 = true;
        cast(void) tuckOwnTmp1;
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑserveˑ7);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ7(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑserveˑ8, &TuckIOˑtuckˑtaskˑserveˑ2);
    }
}

void TuckIOˑtuckˑtaskˑserveˑ2(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "pong");
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ8(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑserveˑ9);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ9(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑserveˑ10, &TuckIOˑtuckˑtaskˑserveˑ3);
    }
}

void TuckIOˑtuckˑtaskˑserveˑ3(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        tuckˑmodˑnet.close(tuckˑvˑc.value.fd);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ10(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        TuckXˑtuckˑtaskˑserveˑ1(tuckF);
        return TuckSˑtuckˑtaskˑserveˑ3(env);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑserveˑ11(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑserve*) env;
    with (*tuckF)
    {
        return TuckSˑtuckˑtaskˑserveˑ3(env);
    }
}

void TuckExitˑtuckˑtaskˑserve(TuckFˑtuckˑtaskˑserve* tuckF)
{
    with (*tuckF)
    {
        if (tuckDefer0)
        {
            rt.tuckDrop(tuckOwnTmp1);
            tuckDefer0 = false;
        }
    }
}
void TuckXˑtuckˑtaskˑserveˑ1(TuckFˑtuckˑtaskˑserve* tuckF)
{
    with (*tuckF)
    {
        if (tuckDefer0)
        {
            rt.tuckDrop(tuckOwnTmp1);
            tuckDefer0 = false;
        }
    }
}

struct TuckFˑtuckˑtaskˑclient
{
    rt.TuckFrameHdr tuckHdr;
    rt.TuckSlot!(bool)* tuckRes;
    bool* tuckDest;
    long port;
    rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)) tuckˑvˑc;
    rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_data!(string)) tuckˑvˑr;
    bool tuckDefer0;
}

TuckFˑtuckˑtaskˑclient* TuckNewˑtuckˑtaskˑclient(TuckFˑtuckˑtaskˑclient* tuckAt, rt.TuckSlot!(bool)* tuckRes, bool* tuckDest, long port)
{
    auto f = tuckAt;
    if (f is null) f = new TuckFˑtuckˑtaskˑclient;
    else { *f = TuckFˑtuckˑtaskˑclient.init; f.tuckHdr.embedded = true; }
    f.tuckHdr.stage = &TuckSˑtuckˑtaskˑclientˑ0;
    f.tuckRes = tuckRes;
    f.tuckDest = tuckDest;
    f.port = port;
    return f;
}

rt.TuckHop TuckRetˑtuckˑtaskˑclient(TuckFˑtuckˑtaskˑclient* tuckF)
{
    if (tuckF.tuckRes !is null) rt.tuckSlComplete(tuckF.tuckRes, true);
    TuckExitˑtuckˑtaskˑclient(tuckF);
    return rt.tuckSlReturnHop(&tuckF.tuckHdr);
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ0(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ1);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ1(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ2, &TuckIOˑtuckˑtaskˑclientˑ0);
    }
}

void TuckIOˑtuckˑtaskˑclientˑ0(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        tuckˑvˑc = tuckˑmodˑnet.connect("127.0.0.1", port);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ2(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        if ((tuckˑvˑc.status == rt.TuckStatus.Ok)) return TuckSˑtuckˑtaskˑclientˑ4(env);
        return TuckSˑtuckˑtaskˑclientˑ19(env);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ3(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ20, &TuckIOˑtuckˑtaskˑclientˑ6);
    }
}

void TuckIOˑtuckˑtaskˑclientˑ6(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        sendPut_tuckˑactorˑResult(tuckˑactorˑResultSingleton, 4L);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ4(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ5);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ5(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ6, &TuckIOˑtuckˑtaskˑclientˑ1);
    }
}

void TuckIOˑtuckˑtaskˑclientˑ1(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "ping");
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ6(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ7);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ7(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ8, &TuckIOˑtuckˑtaskˑclientˑ2);
    }
}

void TuckIOˑtuckˑtaskˑclientˑ2(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        tuckˑvˑr = tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256L);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ8(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        tuckDefer0 = true;
        return rt.tuckSlYield(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ9);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ9(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ10, &TuckIOˑtuckˑtaskˑclientˑ3);
    }
}

void TuckIOˑtuckˑtaskˑclientˑ3(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        tuckˑmodˑnet.close(tuckˑvˑc.value.fd);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ10(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        if ((tuckˑvˑr.status == rt.TuckStatus.Ok)) return TuckSˑtuckˑtaskˑclientˑ12(env);
        return TuckSˑtuckˑtaskˑclientˑ17(env);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ11(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ18, &TuckIOˑtuckˑtaskˑclientˑ5);
    }
}

void TuckIOˑtuckˑtaskˑclientˑ5(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        sendPut_tuckˑactorˑResult(tuckˑactorˑResultSingleton, 3L);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ12(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        if ((tuckˑvˑr.value.data == "pong")) return TuckSˑtuckˑtaskˑclientˑ14(env);
        return TuckSˑtuckˑtaskˑclientˑ16(env);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ13(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return TuckSˑtuckˑtaskˑclientˑ11(env);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ14(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return rt.tuckSlOnStack(&tuckF.tuckHdr, &TuckSˑtuckˑtaskˑclientˑ15, &TuckIOˑtuckˑtaskˑclientˑ4);
    }
}

void TuckIOˑtuckˑtaskˑclientˑ4(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        sendPut_tuckˑactorˑResult(tuckˑactorˑResultSingleton, 42L);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ15(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return TuckRetˑtuckˑtaskˑclient(tuckF);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ16(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return TuckSˑtuckˑtaskˑclientˑ13(env);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ17(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return TuckSˑtuckˑtaskˑclientˑ11(env);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ18(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return TuckRetˑtuckˑtaskˑclient(tuckF);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ19(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return TuckSˑtuckˑtaskˑclientˑ3(env);
    }
}

rt.TuckHop TuckSˑtuckˑtaskˑclientˑ20(void* env)
{
    auto tuckF = cast(TuckFˑtuckˑtaskˑclient*) env;
    with (*tuckF)
    {
        return TuckRetˑtuckˑtaskˑclient(tuckF);
    }
}

void TuckExitˑtuckˑtaskˑclient(TuckFˑtuckˑtaskˑclient* tuckF)
{
    with (*tuckF)
    {
        if (tuckDefer0)
        {
            rt.tuckDrop(tuckˑvˑr);
            tuckDefer0 = false;
        }
    }
}
void TuckXˑtuckˑtaskˑclientˑ1(TuckFˑtuckˑtaskˑclient* tuckF)
{
    with (*tuckF)
    {
        if (tuckDefer0)
        {
            rt.tuckDrop(tuckˑvˑr);
            tuckDefer0 = false;
        }
    }
}

bool tuckˑfnˑdone() {
    return tuckˑactorˑResultSingleton.ready;
}

long tuckˑfnˑmain() {
    rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)) tuckˑvˑl = tuckˑmodˑnet.listen(34593L);
    if ((tuckˑvˑl.status == rt.TuckStatus.Ok)) {
        rt.tuckSlReady(&TuckNewˑtuckˑtaskˑserve(null, null, null, tuckˑvˑl.value.fd).tuckHdr);
        rt.tuckSlReady(&TuckNewˑtuckˑtaskˑclient(null, null, null, 34593L).tuckHdr);
        rt.tuckWaitOn(tuckˑactorˑResultSlot, &tuckˑfnˑdone);
        tuckˑmodˑnet.close(tuckˑvˑl.value.fd);
        tuckˑmodˑscheduler.stop();
        return tuckˑactorˑResultSingleton.code;
    }
    return 1L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuckˑactorˑResultSlot = rt.tuckStartActorFrame(&drain_tuckˑactorˑResult);
    rt.tuckLeakMark();
    auto mainRc = tuckˑfnˑmain();
    rt.tuckSlRunAll();
    rt.tuckRun();
    rt.tuckDrainActors();
    return rt.tuckLeakCheck(cast(int) mainRc);
}
