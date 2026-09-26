module _32_duration_units;

import rt = tuck_rt;
import sys = mod_sys;
import time = mod_time;

struct TRec_ok(T_ok) {
    T_ok ok;
}

long tuckˑfnˑasInt(time.tuckˑtypeˑMilliseconds d) {
    return 42L;
}

TRec_ok!(bool) tuckˑfnˑbudget(time.tuckˑtypeˑMilliseconds d) {
    return TRec_ok!(bool)(ok: true);
}

void tuckˑfnˑmain() {
    TRec_ok!(bool) tuckˑvˑr = tuckˑfnˑbudget(time.tuckˑfnˑms(5L));
    long tuckˑvˑn = tuckˑfnˑasInt(time.tuckˑfnˑms(42L));
    sys.exit(tuckˑvˑn);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
