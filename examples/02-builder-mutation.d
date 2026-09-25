module _02_builder_mutation;

import rt = tuck_rt;

struct tuck_type_ServerConfig {
    long port;
    uint timeout;
    bool running;
}

tuck_type_ServerConfig tuck_fn_withDefaults(tuck_type_ServerConfig self) {
    return tuck_type_ServerConfig(port: 80L, timeout: 30L, running: false);
}

bool tuck_fn_start(tuck_type_ServerConfig self) {
    return true;
}

void tuck_fn_main() {
    tuck_type_ServerConfig tuck_server = tuck_type_ServerConfig(port: 0L, timeout: 0L, running: false);
    tuck_server = tuck_type_ServerConfig(port: 80L, timeout: 30L, running: false);
    tuck_server.port = 8080L;
    tuck_server.timeout = 60L;
    bool tuck_ok = tuck_fn_start(tuck_server);
    return;
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
