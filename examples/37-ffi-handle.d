module _37_ffi_handle;

import rt = tuck_rt;
import sys = mod_sys;

struct CounterObj;
alias Counter = CounterObj*;

extern (C) Counter counterNew(int start);

extern (C) int counterBump(Counter c, int by);

extern (C) void counterFree(Counter c);


void tuck_main() {
    Counter tuck_h = counterNew(100);
    int tuck_t = counterBump(tuck_h, 5);
    counterFree(tuck_h);
    if ((tuck_t == 105)) {
        sys.exit(0);
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
