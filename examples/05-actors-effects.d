module _05_actors_effects;

import rt = tuck_rt;

struct TRec_count_66EB {
    long count;
}

struct TRec_value_B36B {
    ushort value;
}

struct tuck_Feed {
    string title;
    long episodeCount;
}

enum tuck_CounterMsgKind { msgIncrement, msgGet }

struct tuck_CounterMsg {
    tuck_CounterMsgKind kind;
    long n;
}

struct tuck_Counter {
    long count;
    rt.Mailbox!(tuck_CounterMsg, 8) mailbox;
}

__gshared tuck_Counter tuck_CounterSingleton;

void handleMsg_tuck_Counter(ref tuck_Counter self, tuck_CounterMsg msg) {
    final switch (msg.kind) {
        case tuck_CounterMsgKind.msgIncrement:
            auto n = msg.n;
            self.count = (self.count + n);
            break;
        case tuck_CounterMsgKind.msgGet:
            TRec_count_66EB result = TRec_count_66EB(count: self.count);
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

void sendIncrement_tuck_Counter(ref tuck_Counter self, long n) {
    cast(void) rt.enqueue(self.mailbox, tuck_CounterMsg(tuck_CounterMsgKind.msgIncrement, n));
    rt.tuckNotifySend();
}

void sendGet_tuck_Counter(ref tuck_Counter self) {
    cast(void) rt.enqueue(self.mailbox, tuck_CounterMsg(tuck_CounterMsgKind.msgGet));
    rt.tuckNotifySend();
}


rt.TuckResult!(TRec_value_B36B) tuck_readSensor(ubyte port) {
    return typeof(return).init;
}

struct tuck_PodcastApp {
}


