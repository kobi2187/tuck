module _32_duration_units;

import rt = tuck_rt;
import tuckˑmodˑshapes_32_duration_units = mod_shapes_32_duration_units;
import tuckˑmodˑsys = mod_sys;
import tuckˑmodˑtime = mod_time;

long tuckˑfnˑasInt(tuckˑmodˑtime.tuckˑtypeˑMilliseconds d) {
    return 42L;
}

tuckˑmodˑshapes_32_duration_units.TRec_ok!(bool) tuckˑfnˑbudget(tuckˑmodˑtime.tuckˑtypeˑMilliseconds d) {
    return tuckˑmodˑshapes_32_duration_units.TRec_ok!(bool)(ok: true);
}

void tuckˑfnˑmain() {
    tuckˑmodˑshapes_32_duration_units.TRec_ok!(bool) tuckˑvˑr = tuckˑfnˑbudget(tuckˑmodˑtime.tuckˑfnˑms(cast(uint)5));
    long tuckˑvˑn = tuckˑfnˑasInt(tuckˑmodˑtime.tuckˑfnˑms(cast(uint)42));
    tuckˑmodˑsys.exit(tuckˑvˑn);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
