module _26_actor_run;

import rt = tuck_rt;
import scheduler = mod_scheduler;

enum tuck_CounterMsgKind { msgAdd }

struct tuck_CounterMsg {
    tuck_CounterMsgKind kind;
    long n;
}

struct tuck_Counter {
    long total;
    rt.Mailbox!(tuck_CounterMsg, 128) mailbox;
}

__gshared tuck_Counter tuck_CounterSingleton;

void handleMsg_tuck_Counter(ref tuck_Counter self, tuck_CounterMsg msg) {
    final switch (msg.kind) {
        case tuck_CounterMsgKind.msgAdd:
            auto n = msg.n;
            self.total = (self.total + n);
            break;
    }
}

bool drain_tuck_Counter() {
    bool did = false;
    tuck_CounterMsg msg;
    while (rt.dequeue(tuck_CounterSingleton.mailbox, msg)) {
        handleMsg_tuck_Counter(tuck_CounterSingleton, msg);
        did = true;
    }
    return did;
}

void sendAdd_tuck_Counter(ref tuck_Counter self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_CounterMsg(tuck_CounterMsgKind.msgAdd, n));
    rt.tuckNotifySend();
}


bool tuck_sumReady() {
    return (tuck_CounterSingleton.total == 55);
}

long tuck_main() {
    foreach (i; 1 .. 10 + 1) {
        sendAdd_tuck_Counter(tuck_CounterSingleton, i);
    }
    scheduler.waitUntil(&tuck_sumReady);
    return tuck_CounterSingleton.total;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    rt.tuckStartActor(&drain_tuck_Counter);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
