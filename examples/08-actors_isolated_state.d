module _08_actors_isolated_state;

import rt = tuck_rt;

enum tuckˑactorˑTrafficLightStateKind { Red, Yellow, Green }

enum tuckˑactorˑTrafficLightMsgKind { msgNext }

struct tuckˑactorˑTrafficLightMsg {
    tuckˑactorˑTrafficLightMsgKind tuckTag;
}

struct tuckˑactorˑTrafficLight {
    tuckˑactorˑTrafficLightStateKind state;
    rt.Mailbox!(tuckˑactorˑTrafficLightMsg, 4) mailbox;
}

__gshared tuckˑactorˑTrafficLight tuckˑactorˑTrafficLightSingleton;

shared static this() {
    tuckˑactorˑTrafficLightSingleton.state = tuckˑactorˑTrafficLightStateKind.Red;
}

void handleMsg_tuckˑactorˑTrafficLight(ref tuckˑactorˑTrafficLight self, tuckˑactorˑTrafficLightMsg msg) {
    final switch (msg.tuckTag) {
        case tuckˑactorˑTrafficLightMsgKind.msgNext:
            self.state = (() { final switch (self.state) {
    case tuckˑactorˑTrafficLightStateKind.Red: return tuckˑactorˑTrafficLightStateKind.Green;
    case tuckˑactorˑTrafficLightStateKind.Green: return tuckˑactorˑTrafficLightStateKind.Yellow;
    case tuckˑactorˑTrafficLightStateKind.Yellow: return tuckˑactorˑTrafficLightStateKind.Red;
            } })();
            break;
    }
}

__gshared void* tuckˑactorˑTrafficLightSlot;

bool drain_tuckˑactorˑTrafficLight() {
    bool did = false;
    foreach (ref msg; tuckˑactorˑTrafficLightSingleton.mailbox) {
        handleMsg_tuckˑactorˑTrafficLight(tuckˑactorˑTrafficLightSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendNext_tuckˑactorˑTrafficLight(ref tuckˑactorˑTrafficLight self) {
    cast(void) rt.enqueue(self.mailbox, tuckˑactorˑTrafficLightMsg(tuckTag: tuckˑactorˑTrafficLightMsgKind.msgNext));
    rt.tuckNotifySend(tuckˑactorˑTrafficLightSlot);
}


