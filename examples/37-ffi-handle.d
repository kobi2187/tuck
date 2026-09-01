module _37_ffi_handle;

import rt = tuck_rt;
import sys = mod_sys;

struct CounterObj;
alias Counter = CounterObj*;

extern (C) Counter counterNew(int start);

extern (C) int counterBump(Counter c, int by);

extern (C) void counterFree(Counter c);


void tuck_main() {
    Counter h = counterNew(100);
    int t = counterBump(h, 5);
    counterFree(h);
    if ((t == 105)) {
        sys.exit(0);
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
