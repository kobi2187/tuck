module _27_actor_select;

import rt = tuck_rt;
import scheduler = mod_scheduler;

enum tuck_AccumulatorMsgKind { msgAdd, msgFinish, msgShutdown }

struct tuck_AccumulatorMsg {
    tuck_AccumulatorMsgKind kind;
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
    final switch (msg.kind) {
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

bool drain_tuck_Accumulator() {
    if (tuck_AccumulatorSingleton.finished) return false;
    bool did = false;
    tuck_AccumulatorMsg msg;
    while (rt.dequeue(tuck_AccumulatorSingleton.mailbox, msg)) {
        handleMsg_tuck_Accumulator(tuck_AccumulatorSingleton, msg);
        did = true;
    }
    return did;
}

void sendAdd_tuck_Accumulator(ref tuck_Accumulator self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_AccumulatorMsg(tuck_AccumulatorMsgKind.msgAdd, n));
    rt.tuckNotifySend();
}

void sendFinish_tuck_Accumulator(ref tuck_Accumulator self) {
    cast(void) rt.enqueue(self.mailbox, tuck_AccumulatorMsg(tuck_AccumulatorMsgKind.msgFinish));
    rt.tuckNotifySend();
}


bool tuck_ready() {
    return tuck_AccumulatorSingleton.done;
}

long tuck_main() {
    foreach (i; 1 .. 10 + 1) {
        sendAdd_tuck_Accumulator(tuck_AccumulatorSingleton, i);
    }
    sendFinish_tuck_Accumulator(tuck_AccumulatorSingleton);
    scheduler.waitUntil(&tuck_ready);
    return tuck_AccumulatorSingleton.total;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    rt.tuckStartActor(&drain_tuck_Accumulator);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
