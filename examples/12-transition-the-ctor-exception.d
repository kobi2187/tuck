module _12_transition_the_ctor_exception;

import rt = tuck_rt;

struct tuck_Config {
    string url;
}

struct tuck_Feed {
    string title;
}

struct tuck_Socket {
    long fd;
}

enum tuck_PlayerStateKind { Unloaded, Loading, Ready }

struct tuck_PlayerState_Unloaded {
    tuck_Config config;
}

struct tuck_PlayerState_Loading {
    tuck_Config config;
    long progress;
}

struct tuck_PlayerState_Ready {
    tuck_Config config;
    tuck_Feed feed;
}

struct tuck_PlayerState {
    tuck_PlayerStateKind kind;
    union {
        tuck_PlayerState_Unloaded unloaded;
        tuck_PlayerState_Loading loading;
        tuck_PlayerState_Ready ready;
    }
}

enum tuck_MqttSessionKind { Disconnected, Connecting, Connected, Subscribing }

struct tuck_MqttSession_Connecting {
    string host;
    ushort port;
}

struct tuck_MqttSession_Connected {
    tuck_Socket socket;
    ushort keepalive;
}

struct tuck_MqttSession_Subscribing {
    tuck_Socket socket;
    string topic;
}

struct tuck_MqttSession {
    tuck_MqttSessionKind kind;
    union {
        tuck_MqttSession_Connecting connecting;
        tuck_MqttSession_Connected connected;
        tuck_MqttSession_Subscribing subscribing;
    }
}

void tuck_main() {
    tuck_Config tuck_config = tuck_Config(url: "https://example.com");
    tuck_Feed tuck_feed = tuck_Feed(title: "Deep Dive");
    tuck_PlayerState tuck_p = tuck_PlayerState(kind: tuck_PlayerStateKind.Ready, ready: tuck_PlayerState_Ready(config: tuck_config, feed: tuck_feed));
    tuck_MqttSession tuck_fresh = tuck_MqttSession(tuck_MqttSessionKind.Disconnected);
    tuck_Socket tuck_socket = tuck_Socket(fd: 3);
    tuck_MqttSession tuck_session = tuck_MqttSession(kind: tuck_MqttSessionKind.Connected, connected: tuck_MqttSession_Connected(socket: tuck_socket, keepalive: 60));
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
