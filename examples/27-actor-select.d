module _27_actor_select;

import rt = tuck_rt;

enum tuckˑactorˑAccumulatorMsgKind { msgAdd, msgFinish, msgShutdown }

struct tuckˑactorˑAccumulatorMsg {
    tuckˑactorˑAccumulatorMsgKind tuckTag;
    long n;
}

struct tuckˑactorˑAccumulator {
    long total;
    bool done;
    rt.Mailbox!(tuckˑactorˑAccumulatorMsg, 64) mailbox;
    bool finished;
}

__gshared tuckˑactorˑAccumulator tuckˑactorˑAccumulatorSingleton;

shared static this() {
    tuckˑactorˑAccumulatorSingleton.total = 0L;
    tuckˑactorˑAccumulatorSingleton.done = false;
}

void handleMsg_tuckˑactorˑAccumulator(ref tuckˑactorˑAccumulator self, tuckˑactorˑAccumulatorMsg msg) {
    final switch (msg.tuckTag) {
        case tuckˑactorˑAccumulatorMsgKind.msgAdd:
            auto n = msg.n;
            self.total = (self.total + n);
            break;
        case tuckˑactorˑAccumulatorMsgKind.msgFinish:
            self.done = true;
            break;
        case tuckˑactorˑAccumulatorMsgKind.msgShutdown:
            self.total = self.total;
            self.finished = true;
            break;
    }
}

__gshared void* tuckˑactorˑAccumulatorSlot;

bool drain_tuckˑactorˑAccumulator() {
    if (tuckˑactorˑAccumulatorSingleton.finished) return false;
    bool did = false;
    foreach (ref msg; tuckˑactorˑAccumulatorSingleton.mailbox) {
        handleMsg_tuckˑactorˑAccumulator(tuckˑactorˑAccumulatorSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendAdd_tuckˑactorˑAccumulator(ref tuckˑactorˑAccumulator self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑAccumulatorMsg(tuckTag: tuckˑactorˑAccumulatorMsgKind.msgAdd, n: n));
    rt.tuckNotifySend(tuckˑactorˑAccumulatorSlot);
}

void sendFinish_tuckˑactorˑAccumulator(ref tuckˑactorˑAccumulator self) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑAccumulatorMsg(tuckTag: tuckˑactorˑAccumulatorMsgKind.msgFinish));
    rt.tuckNotifySend(tuckˑactorˑAccumulatorSlot);
}


bool tuckˑfnˑready() {
    return tuckˑactorˑAccumulatorSingleton.done;
}

long tuckˑfnˑmain() {
    foreach (tuckˑvˑi; 1L .. 10L + 1) {
        sendAdd_tuckˑactorˑAccumulator(tuckˑactorˑAccumulatorSingleton, tuckˑvˑi);
    }
    sendFinish_tuckˑactorˑAccumulator(tuckˑactorˑAccumulatorSingleton);
    rt.tuckWaitOn(tuckˑactorˑAccumulatorSlot, &tuckˑfnˑready);
    return tuckˑactorˑAccumulatorSingleton.total;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuckˑactorˑAccumulatorSlot = rt.tuckStartActor(&drain_tuckˑactorˑAccumulator);
    auto mainRc = tuckˑfnˑmain();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
