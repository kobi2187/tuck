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
    TRec_ok!(bool) tuckˑvˑr = tuckˑfnˑbudget(time.tuckˑfnˑms(cast(uint)5));
    long tuckˑvˑn = tuckˑfnˑasInt(time.tuckˑfnˑms(cast(uint)42));
    sys.exit(tuckˑvˑn);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
