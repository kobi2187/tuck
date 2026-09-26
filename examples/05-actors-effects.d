module _05_actors_effects;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_value(T_value) {
    T_value value;
}

struct tuck_type_Feed {
    string title;
    long episodeCount;
}

enum tuck_type_CounterMsgKind { msgIncrement, msgReset }

struct tuck_type_CounterMsg {
    tuck_type_CounterMsgKind tuckTag;
    long n;
}

struct tuck_type_Counter {
    long count;
    rt.Mailbox!(tuck_type_CounterMsg, 8) mailbox;
}

__gshared tuck_type_Counter tuck_type_CounterSingleton;

shared static this() {
    tuck_type_CounterSingleton.count = 0L;
}

void handleMsg_tuck_type_Counter(ref tuck_type_Counter self, tuck_type_CounterMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_type_CounterMsgKind.msgIncrement:
            auto n = msg.n;
            self.count = (self.count + n);
            break;
        case tuck_type_CounterMsgKind.msgReset:
            self.count = 0L;
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

void sendIncrement_tuck_type_Counter(ref tuck_type_Counter self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_CounterMsg(tuckTag: tuck_type_CounterMsgKind.msgIncrement, n: n));
    rt.tuckNotifySend(tuck_type_CounterSlot);
}

void sendReset_tuck_type_Counter(ref tuck_type_Counter self) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_CounterMsg(tuckTag: tuck_type_CounterMsgKind.msgReset));
    rt.tuckNotifySend(tuck_type_CounterSlot);
}


rt.TuckResult!(TRec_value!(ushort)) tuck_fn_readSensor(T)(T payload) {
    stderr.writeln("TUCK PENDING: tuck_fn_readSensor invoked (not implemented)");
    return typeof(return).init;
}

struct tuck_type_PodcastApp {
}


