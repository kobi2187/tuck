module _29_task_timeout;

import rt = tuck_rt;
import tuckˑmodˑshapes_29_task_timeout = mod_shapes_29_task_timeout;
import tuckˑmodˑtime = mod_time;

tuckˑmodˑshapes_29_task_timeout.TRec_fd!(long) openSource(long ms) {
    return rt.openSource!(tuckˑmodˑshapes_29_task_timeout.TRec_fd!(long))(ms);
}


tuckˑmodˑshapes_29_task_timeout.TRec_code!(long) tuckˑtaskˑreadOrGiveUp(long fd) {
    long tuckˑvˑcode = 0L;
    if (rt.tuckAwaitReadOrTimeout(fd, tuckˑmodˑtime.tuckˑfnˑms(cast(uint)30))) {
        tuckˑvˑcode = 1L;
    } else {
        tuckˑvˑcode = 2L;
    }
    return tuckˑmodˑshapes_29_task_timeout.TRec_code!(long)(code: tuckˑvˑcode);
}

long tuckˑfnˑmain() {
    tuckˑmodˑshapes_29_task_timeout.TRec_fd!(long) tuckˑvˑsrc = openSource(500L);
    auto tuckSlot1 = rt.newAsyncResult!(tuckˑmodˑshapes_29_task_timeout.TRec_code!(long))();
    rt.spawnResult(tuckSlot1, &tuckˑtaskˑreadOrGiveUp, tuckˑvˑsrc.fd);
    tuckˑmodˑshapes_29_task_timeout.TRec_code!(long) tuckˑvˑr = rt.awaitResult(tuckSlot1);
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
