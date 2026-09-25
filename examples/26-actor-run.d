module _26_actor_run;

import rt = tuck_rt;

enum tuck_CounterMsgKind { msgAdd }

struct tuck_CounterMsg {
    tuck_CounterMsgKind tuckTag;
    long n;
}

struct tuck_Counter {
    long total;
    rt.Mailbox!(tuck_CounterMsg, 128) mailbox;
}

__gshared tuck_Counter tuck_CounterSingleton;

shared static this() {
    tuck_CounterSingleton.total = 0L;
}

void handleMsg_tuck_Counter(ref tuck_Counter self, tuck_CounterMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_CounterMsgKind.msgAdd:
            auto n = msg.n;
            self.total = (self.total + n);
            break;
    }
}

__gshared void* tuck_CounterSlot;

bool drain_tuck_Counter() {
    bool did = false;
    foreach (ref msg; tuck_CounterSingleton.mailbox) {
        handleMsg_tuck_Counter(tuck_CounterSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendAdd_tuck_Counter(ref tuck_Counter self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_CounterMsg(tuckTag: tuck_CounterMsgKind.msgAdd, n: n));
    rt.tuckNotifySend(tuck_CounterSlot);
}


bool tuck_sumReady() {
    return (tuck_CounterSingleton.total == 55L);
}

long tuck_main() {
    foreach (tuck_i; 1L .. 10L + 1) {
        sendAdd_tuck_Counter(tuck_CounterSingleton, tuck_i);
    }
    rt.tuckWaitOn(tuck_CounterSlot, &tuck_sumReady);
    return tuck_CounterSingleton.total;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuck_CounterSlot = rt.tuckStartActor(&drain_tuck_Counter);
    auto mainRc = tuck_main();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
