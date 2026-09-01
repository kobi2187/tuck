module _19_event_registry;

import rt = tuck_rt;

enum tuck_AppEventsKind { SensorFailure, LowMemory }

struct tuck_AppEvents {
    tuck_AppEventsKind kind;
    ubyte port;
    string reason;
    uint remaining;
}

__gshared tuck_AppEvents latesttuck_AppEvents;

void raise_tuck_AppEvents_SensorFailure(ubyte port, string reason) {
    latesttuck_AppEvents = tuck_AppEvents(tuck_AppEventsKind.SensorFailure, port: port, reason: reason);
    tuck_AppEvents_SensorFailure(port, reason);
}

void raise_tuck_AppEvents_LowMemory(uint remaining) {
    latesttuck_AppEvents = tuck_AppEvents(tuck_AppEventsKind.LowMemory, remaining: remaining);
    tuck_AppEvents_LowMemory(remaining);
}


void tuck_triggerEvent() {
    raise_tuck_AppEvents_SensorFailure(1, "timeout");
}

void tuck_AppEvents_SensorFailure(ubyte port, string reason) {
    ubyte x = port;
    string y = reason;
}

void tuck_AppEvents_LowMemory(uint remaining) {
    uint left = remaining;
}

static assert((1 == 1));

