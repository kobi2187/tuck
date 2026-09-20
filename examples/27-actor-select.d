module _27_actor_select;

import rt = tuck_rt;

enum tuck_AccumulatorMsgKind { msgAdd, msgFinish, msgShutdown }

struct tuck_AccumulatorMsg {
    tuck_AccumulatorMsgKind tuckTag;
    long n;
}

struct tuck_Accumulator {
    long total;
    bool done;
    rt.Mailbox!(tuck_AccumulatorMsg, 64) mailbox;
    bool finished;
}

__gshared tuck_Accumulator tuck_AccumulatorSingleton;

void handleMsg_tuck_Accumulator(ref tuck_Accumulator self, tuck_AccumulatorMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_AccumulatorMsgKind.msgAdd:
            auto n = msg.n;
            self.total = (self.total + n);
            break;
        case tuck_AccumulatorMsgKind.msgFinish:
            self.done = true;
            break;
        case tuck_AccumulatorMsgKind.msgShutdown:
            self.total = self.total;
            self.finished = true;
            break;
    }
}

__gshared void* tuck_AccumulatorSlot;

bool drain_tuck_Accumulator() {
    if (tuck_AccumulatorSingleton.finished) return false;
    bool did = false;
    foreach (ref msg; tuck_AccumulatorSingleton.mailbox) {
        handleMsg_tuck_Accumulator(tuck_AccumulatorSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendAdd_tuck_Accumulator(ref tuck_Accumulator self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_AccumulatorMsg(tuckTag: tuck_AccumulatorMsgKind.msgAdd, n: n));
    rt.tuckNotifySend(tuck_AccumulatorSlot);
}

void sendFinish_tuck_Accumulator(ref tuck_Accumulator self) {
    cast(void) rt.enqueue(self.mailbox, tuck_AccumulatorMsg(tuckTag: tuck_AccumulatorMsgKind.msgFinish));
    rt.tuckNotifySend(tuck_AccumulatorSlot);
}


bool tuck_ready() {
    return tuck_AccumulatorSingleton.done;
}

long tuck_main() {
    foreach (tuck_i; 1L .. 10L + 1) {
        sendAdd_tuck_Accumulator(tuck_AccumulatorSingleton, tuck_i);
    }
    sendFinish_tuck_Accumulator(tuck_AccumulatorSingleton);
    rt.tuckWaitOn(tuck_AccumulatorSlot, &tuck_ready);
    return tuck_AccumulatorSingleton.total;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuck_AccumulatorSlot = rt.tuckStartActor(&drain_tuck_Accumulator);
    auto mainRc = tuck_main();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
