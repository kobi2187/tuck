module _02_builder_mutation;

import rt = tuck_rt;

struct tuck_ServerConfig {
    long port;
    uint timeout;
    bool running;
}

tuck_ServerConfig tuck_withDefaults(tuck_ServerConfig self) {
    return tuck_ServerConfig(port: 80L, timeout: 30L, running: false);
}

bool tuck_start(tuck_ServerConfig self) {
    return true;
}

void tuck_main() {
    tuck_ServerConfig tuck_server = tuck_ServerConfig(port: 0L, timeout: 0L, running: false);
    tuck_server = tuck_ServerConfig(port: 80L, timeout: 30L, running: false);
    tuck_server.port = 8080L;
    tuck_server.timeout = 60L;
    bool tuck_ok = tuck_start(tuck_server);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
