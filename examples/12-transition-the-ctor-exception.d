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
    bool opEquals(const tuckˑtypeˑPlayerState o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuckˑtypeˑPlayerStateKind.Unloaded: return tuckˑvariantˑunloaded == o.tuckˑvariantˑunloaded;
        case tuckˑtypeˑPlayerStateKind.Loading: return tuckˑvariantˑloading == o.tuckˑvariantˑloading;
        case tuckˑtypeˑPlayerStateKind.Ready: return tuckˑvariantˑready == o.tuckˑvariantˑready;
        }
    }
    tuckˑtypeˑPlayerState tuckCopyOwned() {
        auto outValue = this;
        final switch (kind) {
        case tuckˑtypeˑPlayerStateKind.Unloaded:
            outValue.tuckˑvariantˑunloaded = rt.tuckCopyG(tuckˑvariantˑunloaded);
            break;
        case tuckˑtypeˑPlayerStateKind.Loading:
            outValue.tuckˑvariantˑloading = rt.tuckCopyG(tuckˑvariantˑloading);
            break;
        case tuckˑtypeˑPlayerStateKind.Ready:
            outValue.tuckˑvariantˑready = rt.tuckCopyG(tuckˑvariantˑready);
            break;
        }
        return outValue;
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
    bool opEquals(const tuckˑtypeˑMqttSession o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuckˑtypeˑMqttSessionKind.Disconnected: return true;
        case tuckˑtypeˑMqttSessionKind.Connecting: return tuckˑvariantˑconnecting == o.tuckˑvariantˑconnecting;
        case tuckˑtypeˑMqttSessionKind.Connected: return tuckˑvariantˑconnected == o.tuckˑvariantˑconnected;
        case tuckˑtypeˑMqttSessionKind.Subscribing: return tuckˑvariantˑsubscribing == o.tuckˑvariantˑsubscribing;
        }
    }
    tuckˑtypeˑMqttSession tuckCopyOwned() {
        auto outValue = this;
        final switch (kind) {
        case tuckˑtypeˑMqttSessionKind.Disconnected:
            break;
        case tuckˑtypeˑMqttSessionKind.Connecting:
            outValue.tuckˑvariantˑconnecting = rt.tuckCopyG(tuckˑvariantˑconnecting);
            break;
        case tuckˑtypeˑMqttSessionKind.Connected:
            outValue.tuckˑvariantˑconnected = rt.tuckCopyG(tuckˑvariantˑconnected);
            break;
        case tuckˑtypeˑMqttSessionKind.Subscribing:
            outValue.tuckˑvariantˑsubscribing = rt.tuckCopyG(tuckˑvariantˑsubscribing);
            break;
        }
        return outValue;
    }
}

void tuckˑfnˑmain() {
    tuckˑtypeˑConfig tuckˑvˑconfig = tuckˑtypeˑConfig(url: rt.tuckCopyG("https://example.com"));
    tuckˑtypeˑFeed tuckˑvˑfeed = tuckˑtypeˑFeed(title: rt.tuckCopyG("Deep Dive"));
    tuckˑtypeˑPlayerState tuckˑvˑp = tuckˑtypeˑPlayerState(kind: tuckˑtypeˑPlayerStateKind.Ready, tuckˑvariantˑready: tuckˑtypeˑPlayerState_Ready(config: tuckˑvˑconfig, feed: tuckˑvˑfeed));
    tuckˑtypeˑMqttSession tuckˑvˑfresh = tuckˑtypeˑMqttSession(tuckˑtypeˑMqttSessionKind.Disconnected);
    tuckˑtypeˑSocket tuckˑvˑsocket = tuckˑtypeˑSocket(fd: 3L);
    tuckˑtypeˑMqttSession tuckˑvˑsession = tuckˑtypeˑMqttSession(kind: tuckˑtypeˑMqttSessionKind.Connected, tuckˑvariantˑconnected: tuckˑtypeˑMqttSession_Connected(socket: tuckˑvˑsocket, keepalive: 60L));
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
