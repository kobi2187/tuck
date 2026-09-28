module _29_task_timeout;

import rt = tuck_rt;
import time = mod_time;

struct TRec_fd(T_fd) {
    T_fd fd;
}

struct TRec_code(T_code) {
    T_code code;
}

TRec_fd!(long) openSource(long ms) {
    return rt.openSource!(TRec_fd!(long))(ms);
}


TRec_code!(long) tuckˑtaskˑreadOrGiveUp(long fd) {
    if (rt.tuckAwaitReadOrTimeout(fd, time.tuckˑfnˑms(30L))) {
        return TRec_code!(long)(code: 1L);
    } else {
        return TRec_code!(long)(code: 2L);
    }
    return typeof(return).init;
}

long tuckˑfnˑmain() {
    TRec_fd!(long) tuckˑvˑsrc = openSource(500L);
    auto tuckSlot1 = rt.newAsyncResult!(TRec_code!(long))();
    rt.spawnResult(tuckSlot1, { return tuckˑtaskˑreadOrGiveUp(tuckˑvˑsrc.fd); });
    TRec_code!(long) tuckˑvˑr = rt.awaitResult(tuckSlot1);
    return tuckˑvˑr.code;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    auto mainRc = tuckˑfnˑmain();
    rt.tuckRun();
    return cast(int) mainRc;
}
