module _19_event_registry;

import rt = tuck_rt;

enum tuckˑregistryˑAppEventsKind { SensorFailure, LowMemory }

struct tuckˑregistryˑAppEvents {
    tuckˑregistryˑAppEventsKind tuckTag;
    ubyte port;
    string reason;
    uint remaining;
}

__gshared tuckˑregistryˑAppEvents latesttuckˑregistryˑAppEvents;

void raise_tuckˑregistryˑAppEvents_SensorFailure(ubyte port, string reason) {
    latesttuckˑregistryˑAppEvents = tuckˑregistryˑAppEvents(tuckˑregistryˑAppEventsKind.SensorFailure, port: port, reason: reason);
    tuckˑfnˑAppEvents_SensorFailure(port, reason);
}

void raise_tuckˑregistryˑAppEvents_LowMemory(uint remaining) {
    latesttuckˑregistryˑAppEvents = tuckˑregistryˑAppEvents(tuckˑregistryˑAppEventsKind.LowMemory, remaining: remaining);
    tuckˑfnˑAppEvents_LowMemory(remaining);
}


void tuckˑfnˑtriggerEvent() {
    raise_tuckˑregistryˑAppEvents_SensorFailure(1L, "timeout");
}

void tuckˑfnˑAppEvents_SensorFailure(ubyte port, string reason) {
    ubyte tuckˑvˑx = port;
    string tuckˑvˑy = reason;
}

void tuckˑfnˑAppEvents_LowMemory(uint remaining) {
    uint tuckˑvˑleft = remaining;
}

static assert((1L == 1L));

