module _29_task_timeout;

import rt = tuck_rt;
import tuckˑmodˑtime = mod_time;

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
    long tuckˑvˑcode = 0L;
    if (rt.tuckAwaitReadOrTimeout(fd, tuckˑmodˑtime.tuckˑfnˑms(cast(uint)30))) {
        tuckˑvˑcode = 1L;
    } else {
        tuckˑvˑcode = 2L;
    }
    return TRec_code!(long)(code: tuckˑvˑcode);
}

long tuckˑfnˑmain() {
    TRec_fd!(long) tuckˑvˑsrc = openSource(500L);
    auto tuckSlot1 = rt.newAsyncResult!(TRec_code!(long))();
    rt.spawnResult(tuckSlot1, &tuckˑtaskˑreadOrGiveUp, tuckˑvˑsrc.fd);
    TRec_code!(long) tuckˑvˑr = rt.awaitResult(tuckSlot1);
    return tuckˑvˑr.code;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckAsyncInit();
    rt.tuckLeakMark();
    auto mainRc = tuckˑfnˑmain();
    rt.tuckRun();
    return rt.tuckLeakCheck(cast(int) mainRc);
}
