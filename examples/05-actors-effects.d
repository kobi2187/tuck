module _05_actors_effects;

import rt = tuck_rt;
import std.stdio : writeln, stderr;

struct TRec_value(T_value) {
    T_value value;
}

struct tuckˑtypeˑFeed {
    string title;
    long episodeCount;
}

enum tuckˑactorˑCounterMsgKind { msgIncrement, msgReset }

struct tuckˑactorˑCounterMsg {
    tuckˑactorˑCounterMsgKind tuckTag;
    long n;
}

struct tuckˑactorˑCounter {
    long count;
    rt.Mailbox!(tuckˑactorˑCounterMsg, 8) mailbox;
}

__gshared tuckˑactorˑCounter tuckˑactorˑCounterSingleton;

shared static this() {
    tuckˑactorˑCounterSingleton.count = 0L;
}

void handleMsg_tuckˑactorˑCounter(ref tuckˑactorˑCounter self, tuckˑactorˑCounterMsg msg) {
    final switch (msg.tuckTag) {
        case tuckˑactorˑCounterMsgKind.msgIncrement:
            auto n = msg.n;
            self.count = (self.count + n);
            break;
        case tuckˑactorˑCounterMsgKind.msgReset:
            self.count = 0L;
            break;
    }
}

__gshared void* tuckˑactorˑCounterSlot;

bool drain_tuckˑactorˑCounter() {
    bool did = false;
    foreach (ref msg; tuckˑactorˑCounterSingleton.mailbox) {
        handleMsg_tuckˑactorˑCounter(tuckˑactorˑCounterSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendIncrement_tuckˑactorˑCounter(ref tuckˑactorˑCounter self, long n) {
    rt.sendWaiting(self.mailbox, tuckˑactorˑCounterMsg(tuckTag: tuckˑactorˑCounterMsgKind.msgIncrement, n: n), tuckˑactorˑCounterSlot, "Counter");
    rt.tuckNotifySend(tuckˑactorˑCounterSlot);
}

void sendReset_tuckˑactorˑCounter(ref tuckˑactorˑCounter self) {
    rt.sendWaiting(self.mailbox, tuckˑactorˑCounterMsg(tuckTag: tuckˑactorˑCounterMsgKind.msgReset), tuckˑactorˑCounterSlot, "Counter");
    rt.tuckNotifySend(tuckˑactorˑCounterSlot);
}


rt.TuckResult!(TRec_value!(ushort)) tuckˑfnˑreadSensor(T)(T payload) {
    stderr.writeln("TUCK PENDING: readSensor invoked (not implemented)");
    return typeof(return).init;
}

struct tuckˑobjectˑPodcastApp {
}


