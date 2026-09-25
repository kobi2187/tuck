module _27_actor_select;

import rt = tuck_rt;

enum tuck_type_AccumulatorMsgKind { msgAdd, msgFinish, msgShutdown }

struct tuck_type_AccumulatorMsg {
    tuck_type_AccumulatorMsgKind tuckTag;
    long n;
}

struct tuck_type_Accumulator {
    long total;
    bool done;
    rt.Mailbox!(tuck_type_AccumulatorMsg, 64) mailbox;
    bool finished;
}

__gshared tuck_type_Accumulator tuck_type_AccumulatorSingleton;

shared static this() {
    tuck_type_AccumulatorSingleton.total = 0L;
    tuck_type_AccumulatorSingleton.done = false;
}

void handleMsg_tuck_type_Accumulator(ref tuck_type_Accumulator self, tuck_type_AccumulatorMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_type_AccumulatorMsgKind.msgAdd:
            auto n = msg.n;
            self.total = (self.total + n);
            break;
        case tuck_type_AccumulatorMsgKind.msgFinish:
            self.done = true;
            break;
        case tuck_type_AccumulatorMsgKind.msgShutdown:
            self.total = self.total;
            self.finished = true;
            break;
    }
}

__gshared void* tuck_type_AccumulatorSlot;

bool drain_tuck_type_Accumulator() {
    if (tuck_type_AccumulatorSingleton.finished) return false;
    bool did = false;
    foreach (ref msg; tuck_type_AccumulatorSingleton.mailbox) {
        handleMsg_tuck_type_Accumulator(tuck_type_AccumulatorSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendAdd_tuck_type_Accumulator(ref tuck_type_Accumulator self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_AccumulatorMsg(tuckTag: tuck_type_AccumulatorMsgKind.msgAdd, n: n));
    rt.tuckNotifySend(tuck_type_AccumulatorSlot);
}

void sendFinish_tuck_type_Accumulator(ref tuck_type_Accumulator self) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_AccumulatorMsg(tuckTag: tuck_type_AccumulatorMsgKind.msgFinish));
    rt.tuckNotifySend(tuck_type_AccumulatorSlot);
}


bool tuck_fn_ready() {
    return tuck_type_AccumulatorSingleton.done;
}

long tuck_fn_main() {
    foreach (tuck_i; 1L .. 10L + 1) {
        sendAdd_tuck_type_Accumulator(tuck_type_AccumulatorSingleton, tuck_i);
    }
    sendFinish_tuck_type_Accumulator(tuck_type_AccumulatorSingleton);
    rt.tuckWaitOn(tuck_type_AccumulatorSlot, &tuck_fn_ready);
    return tuck_type_AccumulatorSingleton.total;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuck_type_AccumulatorSlot = rt.tuckStartActor(&drain_tuck_type_Accumulator);
    auto mainRc = tuck_fn_main();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
