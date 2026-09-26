module _12_transition_the_ctor_exception;

import rt = tuck_rt;

struct tuck_type_Config {
    string url;
}

struct tuck_type_Feed {
    string title;
}

struct tuck_type_Socket {
    long fd;
}

enum tuck_type_PlayerStateKind { Unloaded, Loading, Ready }

struct tuck_type_PlayerState_Unloaded {
    tuck_type_Config config;
}

struct tuck_type_PlayerState_Loading {
    tuck_type_Config config;
    long progress;
}

struct tuck_type_PlayerState_Ready {
    tuck_type_Config config;
    tuck_type_Feed feed;
}

struct tuck_type_PlayerState {
    tuck_type_PlayerStateKind kind;
    union {
        tuck_type_PlayerState_Unloaded tuck_unloaded;
        tuck_type_PlayerState_Loading tuck_loading;
        tuck_type_PlayerState_Ready tuck_ready;
    }
    bool opEquals(const tuck_type_PlayerState o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuck_type_PlayerStateKind.Unloaded: return tuck_unloaded == o.tuck_unloaded;
        case tuck_type_PlayerStateKind.Loading: return tuck_loading == o.tuck_loading;
        case tuck_type_PlayerStateKind.Ready: return tuck_ready == o.tuck_ready;
        }
    }
}

enum tuck_type_MqttSessionKind { Disconnected, Connecting, Connected, Subscribing }

struct tuck_type_MqttSession_Connecting {
    string host;
    ushort port;
}

struct tuck_type_MqttSession_Connected {
    tuck_type_Socket socket;
    ushort keepalive;
}

struct tuck_type_MqttSession_Subscribing {
    tuck_type_Socket socket;
    string topic;
}

struct tuck_type_MqttSession {
    tuck_type_MqttSessionKind kind;
    union {
        tuck_type_MqttSession_Connecting tuck_connecting;
        tuck_type_MqttSession_Connected tuck_connected;
        tuck_type_MqttSession_Subscribing tuck_subscribing;
    }
    bool opEquals(const tuck_type_MqttSession o) const {
        if (kind != o.kind) return false;
        final switch (kind) {
        case tuck_type_MqttSessionKind.Disconnected: return true;
        case tuck_type_MqttSessionKind.Connecting: return tuck_connecting == o.tuck_connecting;
        case tuck_type_MqttSessionKind.Connected: return tuck_connected == o.tuck_connected;
        case tuck_type_MqttSessionKind.Subscribing: return tuck_subscribing == o.tuck_subscribing;
        }
    }
}

void tuck_fn_main() {
    tuck_type_Config tuck_config = tuck_type_Config(url: "https://example.com");
    tuck_type_Feed tuck_feed = tuck_type_Feed(title: "Deep Dive");
    tuck_type_PlayerState tuck_p = tuck_type_PlayerState(kind: tuck_type_PlayerStateKind.Ready, tuck_ready: tuck_type_PlayerState_Ready(config: tuck_config, feed: tuck_feed));
    tuck_type_MqttSession tuck_fresh = tuck_type_MqttSession(tuck_type_MqttSessionKind.Disconnected);
    tuck_type_Socket tuck_socket = tuck_type_Socket(fd: 3L);
    tuck_type_MqttSession tuck_session = tuck_type_MqttSession(kind: tuck_type_MqttSessionKind.Connected, tuck_connected: tuck_type_MqttSession_Connected(socket: tuck_socket, keepalive: 60L));
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
