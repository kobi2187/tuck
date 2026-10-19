module _30_async_read;

import rt = tuck_rt;
import tuckˑmodˑshapes_30_async_read = mod_shapes_30_async_read;
import tuckˑmodˑtime = mod_time;

tuckˑmodˑshapes_30_async_read.TRec_fd!(long) openSource(long ms) {
    return rt.openSource!(tuckˑmodˑshapes_30_async_read.TRec_fd!(long))(ms);
}


tuckˑmodˑshapes_30_async_read.TRec_code!(long) tuckˑtaskˑreadOrGiveUp(long fd) {
    long tuckˑvˑcode = 0L;
    if (rt.tuckAwaitReadOrTimeout(fd, tuckˑmodˑtime.tuckˑfnˑms(cast(uint)100))) {
        tuckˑvˑcode = 1L;
    } else {
        tuckˑvˑcode = 2L;
    }
    return tuckˑmodˑshapes_30_async_read.TRec_code!(long)(code: tuckˑvˑcode);
}

long tuckˑfnˑmain() {
    tuckˑmodˑshapes_30_async_read.TRec_fd!(long) tuckˑvˑsrc = openSource(5L);
    auto tuckSlot1 = rt.newAsyncResult!(tuckˑmodˑshapes_30_async_read.TRec_code!(long))();
    rt.spawnResult(tuckSlot1, &tuckˑtaskˑreadOrGiveUp, tuckˑvˑsrc.fd);
    tuckˑmodˑshapes_30_async_read.TRec_code!(long) tuckˑvˑr = rt.awaitResult(tuckSlot1);
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
