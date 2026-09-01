module _08_actors_isolated_state;

import rt = tuck_rt;

enum tuck_TrafficLightStateKind { Red, Yellow, Green }

enum tuck_TrafficLightMsgKind { msgNext }

struct tuck_TrafficLightMsg {
    tuck_TrafficLightMsgKind kind;
}

struct tuck_TrafficLight {
    tuck_TrafficLightStateKind state;
    rt.Mailbox!(tuck_TrafficLightMsg, 4) mailbox;
}

__gshared tuck_TrafficLight tuck_TrafficLightSingleton;

void handleMsg_tuck_TrafficLight(ref tuck_TrafficLight self, tuck_TrafficLightMsg msg) {
    final switch (msg.kind) {
        case tuck_TrafficLightMsgKind.msgNext:
            self.state = (() { final switch (self.state) {
    case tuck_TrafficLightStateKind.Red: return tuck_TrafficLightStateKind.Green;
    case tuck_TrafficLightStateKind.Green: return tuck_TrafficLightStateKind.Yellow;
    case tuck_TrafficLightStateKind.Yellow: return tuck_TrafficLightStateKind.Red;
            } })();
            break;
    }
}

bool drain_tuck_TrafficLight() {
    bool did = false;
    tuck_TrafficLightMsg msg;
    while (rt.dequeue(tuck_TrafficLightSingleton.mailbox, msg)) {
        handleMsg_tuck_TrafficLight(tuck_TrafficLightSingleton, msg);
        did = true;
    }
    return did;
}

void sendNext_tuck_TrafficLight(ref tuck_TrafficLight self) {
    cast(void) rt.enqueue(self.mailbox, tuck_TrafficLightMsg(tuck_TrafficLightMsgKind.msgNext));
    rt.tuckNotifySend();
}


