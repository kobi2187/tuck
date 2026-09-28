module _37_ffi_handle;

import rt = tuck_rt;
import sys = mod_sys;

struct CounterObj;
alias Counter = CounterObj*;

extern (C) Counter counterNew(int start);

extern (C) int counterBump(Counter c, int by);

extern (C) void counterFree(Counter c);


void tuckˑfnˑmain() {
    Counter tuckˑvˑh = counterNew(100L);
    int tuckˑvˑt = counterBump(tuckˑvˑh, 5L);
    counterFree(tuckˑvˑh);
    if ((tuckˑvˑt == 105L)) {
        sys.exit(0L);
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
