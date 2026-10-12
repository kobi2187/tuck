module _12_transition_the_ctor_exception;

import rt = tuck_rt;

struct tuckˑtypeˑConfig {
    string url;
}

struct tuckˑtypeˑFeed {
    string title;
}

struct tuckˑtypeˑSocket {
    long fd;
}

enum tuckˑtypeˑPlayerStateKind { Unloaded, Loading, Ready }

struct tuckˑtypeˑPlayerState_Unloaded {
    tuckˑtypeˑConfig config;
}

struct tuckˑtypeˑPlayerState_Loading {
    tuckˑtypeˑConfig config;
    long progress;
}

struct tuckˑtypeˑPlayerState_Ready {
    tuckˑtypeˑConfig config;
    tuckˑtypeˑFeed feed;
}

struct tuckˑtypeˑPlayerState {
    tuckˑtypeˑPlayerStateKind kind;
    union {
        tuckˑtypeˑPlayerState_Unloaded tuckˑvariantˑunloaded;
        tuckˑtypeˑPlayerState_Loading tuckˑvariantˑloading;
        tuckˑtypeˑPlayerState_Ready tuckˑvariantˑready;
    }
    void tuckFree() {
        final switch (kind) {
        case tuckˑtypeˑPlayerStateKind.Unloaded: rt.tuckDrop(tuckˑvariantˑunloaded); break;
        case tuckˑtypeˑPlayerStateKind.Loading: rt.tuckDrop(tuckˑvariantˑloading); break;
        case tuckˑtypeˑPlayerStateKind.Ready: rt.tuckDrop(tuckˑvariantˑready); break;
        }
    }
    tuckˑtypeˑPlayerState tuckDup() {
        tuckˑtypeˑPlayerState r = this;
        final switch (kind) {
        case tuckˑtypeˑPlayerStateKind.Unloaded: r.tuckˑvariantˑunloaded = rt.tuckCopy(tuckˑvariantˑunloaded); break;
        case tuckˑtypeˑPlayerStateKind.Loading: r.tuckˑvariantˑloading = rt.tuckCopy(tuckˑvariantˑloading); break;
        case tuckˑtypeˑPlayerStateKind.Ready: r.tuckˑvariantˑready = rt.tuckCopy(tuckˑvariantˑready); break;
        }
        return r;
    }
    bool opEquals(const tuckˑtypeˑPlayerState o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuckˑtypeˑPlayerStateKind.Unloaded: return tuckˑvariantˑunloaded == o.tuckˑvariantˑunloaded;
        case tuckˑtypeˑPlayerStateKind.Loading: return tuckˑvariantˑloading == o.tuckˑvariantˑloading;
        case tuckˑtypeˑPlayerStateKind.Ready: return tuckˑvariantˑready == o.tuckˑvariantˑready;
        }
    }
}

enum tuckˑtypeˑMqttSessionKind { Disconnected, Connecting, Connected, Subscribing }

struct tuckˑtypeˑMqttSession_Connecting {
    string host;
    ushort port;
}

struct tuckˑtypeˑMqttSession_Connected {
    tuckˑtypeˑSocket socket;
    ushort keepalive;
}

struct tuckˑtypeˑMqttSession_Subscribing {
    tuckˑtypeˑSocket socket;
    string topic;
}

struct tuckˑtypeˑMqttSession {
    tuckˑtypeˑMqttSessionKind kind;
    union {
        tuckˑtypeˑMqttSession_Connecting tuckˑvariantˑconnecting;
        tuckˑtypeˑMqttSession_Connected tuckˑvariantˑconnected;
        tuckˑtypeˑMqttSession_Subscribing tuckˑvariantˑsubscribing;
    }
    void tuckFree() {
        final switch (kind) {
        case tuckˑtypeˑMqttSessionKind.Disconnected: break;
        case tuckˑtypeˑMqttSessionKind.Connecting: rt.tuckDrop(tuckˑvariantˑconnecting); break;
        case tuckˑtypeˑMqttSessionKind.Connected: rt.tuckDrop(tuckˑvariantˑconnected); break;
        case tuckˑtypeˑMqttSessionKind.Subscribing: rt.tuckDrop(tuckˑvariantˑsubscribing); break;
        }
    }
    tuckˑtypeˑMqttSession tuckDup() {
        tuckˑtypeˑMqttSession r = this;
        final switch (kind) {
        case tuckˑtypeˑMqttSessionKind.Disconnected: break;
        case tuckˑtypeˑMqttSessionKind.Connecting: r.tuckˑvariantˑconnecting = rt.tuckCopy(tuckˑvariantˑconnecting); break;
        case tuckˑtypeˑMqttSessionKind.Connected: r.tuckˑvariantˑconnected = rt.tuckCopy(tuckˑvariantˑconnected); break;
        case tuckˑtypeˑMqttSessionKind.Subscribing: r.tuckˑvariantˑsubscribing = rt.tuckCopy(tuckˑvariantˑsubscribing); break;
        }
        return r;
    }
    bool opEquals(const tuckˑtypeˑMqttSession o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuckˑtypeˑMqttSessionKind.Disconnected: return true;
        case tuckˑtypeˑMqttSessionKind.Connecting: return tuckˑvariantˑconnecting == o.tuckˑvariantˑconnecting;
        case tuckˑtypeˑMqttSessionKind.Connected: return tuckˑvariantˑconnected == o.tuckˑvariantˑconnected;
        case tuckˑtypeˑMqttSessionKind.Subscribing: return tuckˑvariantˑsubscribing == o.tuckˑvariantˑsubscribing;
        }
    }
}

void tuckˑfnˑmain() {
    tuckˑtypeˑConfig tuckˑvˑconfig = tuckˑtypeˑConfig(url: ("https://example.com").idup);
    tuckˑtypeˑFeed tuckˑvˑfeed = tuckˑtypeˑFeed(title: ("Deep Dive").idup);
    tuckˑtypeˑPlayerState tuckˑvˑp = tuckˑtypeˑPlayerState(kind: tuckˑtypeˑPlayerStateKind.Ready, tuckˑvariantˑready: tuckˑtypeˑPlayerState_Ready(config: tuckˑvˑconfig, feed: tuckˑvˑfeed));
    scope(exit) rt.tuckDrop(tuckˑvˑp);
    tuckˑtypeˑMqttSession tuckˑvˑfresh = tuckˑtypeˑMqttSession(tuckˑtypeˑMqttSessionKind.Disconnected);
    scope(exit) rt.tuckDrop(tuckˑvˑfresh);
    tuckˑtypeˑSocket tuckˑvˑsocket = tuckˑtypeˑSocket(fd: 3L);
    tuckˑtypeˑMqttSession tuckˑvˑsession = tuckˑtypeˑMqttSession(kind: tuckˑtypeˑMqttSessionKind.Connected, tuckˑvariantˑconnected: tuckˑtypeˑMqttSession_Connected(socket: tuckˑvˑsocket, keepalive: 60L));
    scope(exit) rt.tuckDrop(tuckˑvˑsession);
    return;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
