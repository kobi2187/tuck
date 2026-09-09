module _37_ffi_handle;

import rt = tuck_rt;
import sys = mod_sys;

struct CounterObj;
alias Counter = CounterObj*;

extern (C) Counter counterNew(int start);

extern (C) int counterBump(Counter c, int by);

extern (C) void counterFree(Counter c);


void tuck_main() {
    Counter tuck_h = counterNew(100L);
    int tuck_t = counterBump(tuck_h, 5L);
    counterFree(tuck_h);
    if ((tuck_t == 105L)) {
        sys.exit(0L);
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
