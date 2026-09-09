module _29_task_timeout;

import rt = tuck_rt;
import time = mod_time;

struct TRec_fd_EC6A {
    long fd;
}

struct TRec_code_C9C6 {
    long code;
}

TRec_fd_EC6A openSource(long ms) {
    return rt.openSource!(TRec_fd_EC6A)(ms);
}


TRec_code_C9C6 tuck_readOrGiveUp(long fd) {
    if (rt.tuckAwaitReadOrTimeout(fd, time.tuck_ms(30L))) {
        return TRec_code_C9C6(code: 1L);
    } else {
        return TRec_code_C9C6(code: 2L);
    }
    return typeof(return).init;
}

long tuck_main() {
    TRec_fd_EC6A tuck_src = openSource(500L);
    auto tuckSlot1 = rt.newAsyncResult!(TRec_code_C9C6)();
    rt.spawnResult(tuckSlot1, { return tuck_readOrGiveUp(tuck_src.fd); });
    TRec_code_C9C6 tuck_r = rt.awaitResult(tuckSlot1);
    return tuck_r.code;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    auto mainRc = tuck_main();
    rt.tuckRun();
    return cast(int) mainRc;
}
