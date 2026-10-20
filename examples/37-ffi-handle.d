module _37_ffi_handle;

import rt = tuck_rt;
import tuckˑmodˑsys = mod_sys;

struct CounterObj;
alias Counter = CounterObj*;

extern (C) Counter counterNew(int start);

extern (C) int counterBump(Counter c, int by);

extern (C) void counterFree(Counter c);


void tuckˑfnˑmain() {
    Counter tuckˑvˑh = counterNew(cast(int)100);
    int tuckˑvˑt = counterBump(tuckˑvˑh, cast(int)5);
    counterFree(tuckˑvˑh);
    if ((tuckˑvˑt == cast(int)105)) {
        tuckˑmodˑsys.exit(0L);
    }
    tuckˑmodˑsys.exit(1L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
