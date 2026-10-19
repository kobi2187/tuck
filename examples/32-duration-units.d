module _32_duration_units;

import rt = tuck_rt;
import tuckˑmodˑsys = mod_sys;
import tuckˑmodˑtime = mod_time;

struct TRec_ok(T_ok) {
    T_ok ok;
}

long tuckˑfnˑasInt(tuckˑmodˑtime.tuckˑtypeˑMilliseconds d) {
    return 42L;
}

TRec_ok!(bool) tuckˑfnˑbudget(tuckˑmodˑtime.tuckˑtypeˑMilliseconds d) {
    return TRec_ok!(bool)(ok: true);
}

void tuckˑfnˑmain() {
    TRec_ok!(bool) tuckˑvˑr = tuckˑfnˑbudget(tuckˑmodˑtime.tuckˑfnˑms(cast(uint)5));
    long tuckˑvˑn = tuckˑfnˑasInt(tuckˑmodˑtime.tuckˑfnˑms(cast(uint)42));
    tuckˑmodˑsys.exit(tuckˑvˑn);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
