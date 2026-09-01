module _02_builder_mutation;

import rt = tuck_rt;

struct tuck_ServerConfig {
    long port;
    uint timeout;
    bool running;
}

tuck_ServerConfig tuck_withDefaults(tuck_ServerConfig self) {
    return tuck_ServerConfig(port: 80, timeout: 30, running: false);
}

bool tuck_start(tuck_ServerConfig self) {
    return true;
}

void tuck_main() {
    tuck_ServerConfig server = tuck_ServerConfig(port: 0, timeout: 0, running: false);
    server = tuck_ServerConfig(port: 80, timeout: 30, running: false);
    server.port = 8080;
    server.timeout = 60;
    bool ok = tuck_start(server);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
