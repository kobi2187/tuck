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


void tuckˑtaskˑserve(long lfd) {
    rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)) tuckˑvˑc = tuckˑmodˑnet.accept(lfd);
    if ((tuckˑvˑc.status == rt.TuckStatus.Ok)) {
        rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_data!(string)) tuckOwnTmp1 = tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256L);
        scope(exit) rt.tuckDrop(tuckOwnTmp1);
        cast(void) tuckOwnTmp1;
        tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "pong");
        tuckˑmodˑnet.close(tuckˑvˑc.value.fd);
    }
    return;
}

void tuckˑtaskˑclient(long port) {
    rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)) tuckˑvˑc = tuckˑmodˑnet.connect("127.0.0.1", port);
    if ((tuckˑvˑc.status == rt.TuckStatus.Ok)) {
        tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "ping");
        rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_data!(string)) tuckˑvˑr = tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256L);
        scope(exit) rt.tuckDrop(tuckˑvˑr);
        tuckˑmodˑnet.close(tuckˑvˑc.value.fd);
        if ((tuckˑvˑr.status == rt.TuckStatus.Ok)) {
            if ((tuckˑvˑr.value.data == "pong")) {
                sendPut_tuckˑactorˑResult(tuckˑactorˑResultSingleton, 42L);
                return;
            }
        }
        sendPut_tuckˑactorˑResult(tuckˑactorˑResultSingleton, 3L);
        return;
    }
    sendPut_tuckˑactorˑResult(tuckˑactorˑResultSingleton, 4L);
    return;
}

bool tuckˑfnˑdone() {
    return tuckˑactorˑResultSingleton.ready;
}

long tuckˑfnˑmain() {
    rt.TuckResult!(tuckˑmodˑshapes_42_net_echo.TRec_fd!(long)) tuckˑvˑl = tuckˑmodˑnet.listen(34593L);
    if ((tuckˑvˑl.status == rt.TuckStatus.Ok)) {
        rt.tuckSpawnJob(&tuckˑtaskˑserve, tuckˑvˑl.value.fd);
        rt.tuckSpawnJob(&tuckˑtaskˑclient, 34593L);
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
    tuckˑactorˑResultSlot = rt.tuckStartActor(&drain_tuckˑactorˑResult);
    rt.tuckLeakMark();
    auto mainRc = tuckˑfnˑmain();
    rt.tuckRun();
    rt.tuckDrainActors();
    return rt.tuckLeakCheck(cast(int) mainRc);
}
