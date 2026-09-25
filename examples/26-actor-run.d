module _26_actor_run;

import rt = tuck_rt;

enum tuck_type_CounterMsgKind { msgAdd }

struct tuck_type_CounterMsg {
    tuck_type_CounterMsgKind tuckTag;
    long n;
}

struct tuck_type_Counter {
    long total;
    rt.Mailbox!(tuck_type_CounterMsg, 128) mailbox;
}

__gshared tuck_type_Counter tuck_type_CounterSingleton;

shared static this() {
    tuck_type_CounterSingleton.total = 0L;
}

void handleMsg_tuck_type_Counter(ref tuck_type_Counter self, tuck_type_CounterMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_type_CounterMsgKind.msgAdd:
            auto n = msg.n;
            self.total = (self.total + n);
            break;
    }
}

__gshared void* tuck_type_CounterSlot;

bool drain_tuck_type_Counter() {
    bool did = false;
    foreach (ref msg; tuck_type_CounterSingleton.mailbox) {
        handleMsg_tuck_type_Counter(tuck_type_CounterSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendAdd_tuck_type_Counter(ref tuck_type_Counter self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_CounterMsg(tuckTag: tuck_type_CounterMsgKind.msgAdd, n: n));
    rt.tuckNotifySend(tuck_type_CounterSlot);
}


bool tuck_fn_sumReady() {
    return (tuck_type_CounterSingleton.total == 55L);
}

long tuck_fn_main() {
    foreach (tuck_i; 1L .. 10L + 1) {
        sendAdd_tuck_type_Counter(tuck_type_CounterSingleton, tuck_i);
    }
    rt.tuckWaitOn(tuck_type_CounterSlot, &tuck_fn_sumReady);
    return tuck_type_CounterSingleton.total;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    tuck_type_CounterSlot = rt.tuckStartActor(&drain_tuck_type_Counter);
    auto mainRc = tuck_fn_main();
    rt.tuckDrainActors();
    return cast(int) mainRc;
}
