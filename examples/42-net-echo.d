module _42_net_echo;

import rt = tuck_rt;
import scheduler = mod_scheduler;
import net = mod_net;

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
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑResultMsg(tuckTag: tuckˑactorˑResultMsgKind.msgPut, c: c));
    rt.tuckNotifySend(tuckˑactorˑResultSlot);
}


void tuckˑtaskˑserve(long lfd) {
    rt.TuckResult!(net.TRec_net_fd!(long)) tuckˑvˑc = net.accept(lfd);
    if ((tuckˑvˑc.status == rt.TuckStatus.Ok)) {
        net.recv(tuckˑvˑc.value.fd, 256L);
        net.send(tuckˑvˑc.value.fd, "pong");
        net.close(tuckˑvˑc.value.fd);
    }
    return;
}

void tuckˑtaskˑclient(long port) {
    rt.TuckResult!(net.TRec_net_fd!(long)) tuckˑvˑc = net.connect("127.0.0.1", port);
    if ((tuckˑvˑc.status == rt.TuckStatus.Ok)) {
        net.send(tuckˑvˑc.value.fd, "ping");
        rt.TuckResult!(net.TRec_net_data!(string)) tuckˑvˑr = net.recv(tuckˑvˑc.value.fd, 256L);
        net.close(tuckˑvˑc.value.fd);
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
    rt.TuckResult!(net.TRec_net_fd!(long)) tuckˑvˑl = net.listen(34593L);
    if ((tuckˑvˑl.status == rt.TuckStatus.Ok)) {
        rt.tuckSpawn({ cast(void) tuckˑtaskˑserve(tuckˑvˑl.value.fd); });
        rt.tuckSpawn({ cast(void) tuckˑtaskˑclient(34593L); });
        rt.tuckWaitOn(tuckˑactorˑResultSlot, &tuckˑfnˑdone);
        net.close(tuckˑvˑl.value.fd);
        scheduler.stop();
        return tuckˑactorˑResultSingleton.code;
    }
    return 1L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuckˑactorˑResultSlot = rt.tuckStartActor(&drain_tuckˑactorˑResult);
    auto mainRc = tuckˑfnˑmain();
    rt.tuckRun();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
