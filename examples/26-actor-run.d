module _26_actor_run;

import rt = tuck_rt;

enum tuckˑactorˑCounterMsgKind { msgAdd }

struct tuckˑactorˑCounterMsg {
    tuckˑactorˑCounterMsgKind tuckTag;
    long n;
}

struct tuckˑactorˑCounter {
    long total;
    rt.Mailbox!(tuckˑactorˑCounterMsg, 128) mailbox;
}

__gshared tuckˑactorˑCounter tuckˑactorˑCounterSingleton;

shared static this() {
    tuckˑactorˑCounterSingleton.total = 0L;
}

void handleMsg_tuckˑactorˑCounter(ref tuckˑactorˑCounter self, tuckˑactorˑCounterMsg msg) {
    final switch (msg.tuckTag) {
        case tuckˑactorˑCounterMsgKind.msgAdd:
            auto n = msg.n;
            self.total = (self.total + n);
            break;
    }
}

__gshared void* tuckˑactorˑCounterSlot;

bool drain_tuckˑactorˑCounter() {
    bool did = false;
    foreach (ref msg; tuckˑactorˑCounterSingleton.mailbox) {
        handleMsg_tuckˑactorˑCounter(tuckˑactorˑCounterSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendAdd_tuckˑactorˑCounter(ref tuckˑactorˑCounter self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑCounterMsg(tuckTag: tuckˑactorˑCounterMsgKind.msgAdd, n: n));
    rt.tuckNotifySend(tuckˑactorˑCounterSlot);
}


bool tuckˑfnˑsumReady() {
    return (tuckˑactorˑCounterSingleton.total == 55L);
}

long tuckˑfnˑmain() {
    foreach (tuckˑvˑi; 1L .. 10L + 1) {
        sendAdd_tuckˑactorˑCounter(tuckˑactorˑCounterSingleton, tuckˑvˑi);
    }
    rt.tuckWaitOn(tuckˑactorˑCounterSlot, &tuckˑfnˑsumReady);
    return tuckˑactorˑCounterSingleton.total;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuckˑactorˑCounterSlot = rt.tuckStartActor(&drain_tuckˑactorˑCounter);
    auto mainRc = tuckˑfnˑmain();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
