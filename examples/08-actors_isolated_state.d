module _08_actors_isolated_state;

import rt = tuck_rt;

enum tuck_type_TrafficLightStateKind { Red, Yellow, Green }

enum tuck_type_TrafficLightMsgKind { msgNext }

struct tuck_type_TrafficLightMsg {
    tuck_type_TrafficLightMsgKind tuckTag;
}

struct tuck_type_TrafficLight {
    tuck_type_TrafficLightStateKind state;
    rt.Mailbox!(tuck_type_TrafficLightMsg, 4) mailbox;
}

__gshared tuck_type_TrafficLight tuck_type_TrafficLightSingleton;

shared static this() {
    tuck_type_TrafficLightSingleton.state = tuck_type_TrafficLightStateKind.Red;
}

void handleMsg_tuck_type_TrafficLight(ref tuck_type_TrafficLight self, tuck_type_TrafficLightMsg msg) {
    final switch (msg.tuckTag) {
        case tuck_type_TrafficLightMsgKind.msgNext:
            self.state = (() { final switch (self.state) {
    case tuck_type_TrafficLightStateKind.Red: return tuck_type_TrafficLightStateKind.Green;
    case tuck_type_TrafficLightStateKind.Green: return tuck_type_TrafficLightStateKind.Yellow;
    case tuck_type_TrafficLightStateKind.Yellow: return tuck_type_TrafficLightStateKind.Red;
            } })();
            break;
    }
}

__gshared void* tuck_type_TrafficLightSlot;

bool drain_tuck_type_TrafficLight() {
    bool did = false;
    foreach (ref msg; tuck_type_TrafficLightSingleton.mailbox) {
        handleMsg_tuck_type_TrafficLight(tuck_type_TrafficLightSingleton, msg);
        rt.tuckCheckWaiters();
        did = true;
    }
    return did;
}

void sendNext_tuck_type_TrafficLight(ref tuck_type_TrafficLight self) {
    cast(void) rt.enqueue(self.mailbox, tuck_type_TrafficLightMsg(tuckTag: tuck_type_TrafficLightMsgKind.msgNext));
    rt.tuckNotifySend(tuck_type_TrafficLightSlot);
}


