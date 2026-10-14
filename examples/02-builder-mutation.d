module _02_builder_mutation;

import rt = tuck_rt;

struct tuckˑtypeˑServerConfig {
    long port;
    uint timeout;
    bool running;
}

tuckˑtypeˑServerConfig tuckˑfnˑwithDefaults(tuckˑtypeˑServerConfig self) {
    return tuckˑtypeˑServerConfig(port: 80L, timeout: cast(uint)30, running: false);
}

bool tuckˑfnˑstart(tuckˑtypeˑServerConfig self) {
    return true;
}

void tuckˑfnˑmain() {
    tuckˑtypeˑServerConfig tuckˑvˑserver = tuckˑtypeˑServerConfig(port: 0L, timeout: cast(uint)0, running: false);
    tuckˑvˑserver = tuckˑtypeˑServerConfig(port: 80L, timeout: cast(uint)30, running: false);
    tuckˑvˑserver.port = 8080L;
    tuckˑvˑserver.timeout = cast(uint)60;
    bool tuckˑvˑok = tuckˑfnˑstart(tuckˑvˑserver);
    return;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
