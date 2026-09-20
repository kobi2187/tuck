module _05_actors_effects;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_value(T_value) {
    T_value value;
}

struct tuck_Feed {
    string title;
    long episodeCount;
}

enum tuck_CounterMsgKind { msgIncrement, msgReset }

struct tuck_CounterMsg {
    tuck_CounterMsgKind tuckTag;
    long n;
}

struct tuck_Counter {
    long count;
    rt.Mailbox!(tuck_CounterMsg, 8) mailbox;
}

__gshared tuck_Counter tuck_CounterSingleton;

void handleMsg_tuck_Counter(ref tuck_Counter self, tuck_CounterMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_CounterMsgKind.msgIncrement:
            auto n = msg.n;
            self.count = (self.count + n);
            break;
        case tuck_CounterMsgKind.msgReset:
            self.count = 0L;
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

void sendIncrement_tuck_Counter(ref tuck_Counter self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_CounterMsg(tuckTag: tuck_CounterMsgKind.msgIncrement, n: n));
    rt.tuckNotifySend(tuck_CounterSlot);
}

void sendReset_tuck_Counter(ref tuck_Counter self) {
    cast(void) rt.enqueue(self.mailbox, tuck_CounterMsg(tuckTag: tuck_CounterMsgKind.msgReset));
    rt.tuckNotifySend(tuck_CounterSlot);
}


rt.TuckResult!(TRec_value!(ushort)) tuck_readSensor(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_readSensor invoked (not implemented)");
    return typeof(return).init;
}

struct tuck_PodcastApp {
}


