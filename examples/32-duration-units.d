module _32_duration_units;

import rt = tuck_rt;
import sys = mod_sys;
import time = mod_time;

struct TRec_ok(T_ok) {
    T_ok ok;
}

long tuck_asInt(time.tuck_Milliseconds d) {
    return 42L;
}

TRec_ok!(bool) tuck_budget(time.tuck_Milliseconds d) {
    return TRec_ok!(bool)(ok: true);
}

void tuck_main() {
    TRec_ok!(bool) tuck_r = tuck_budget(time.tuck_ms(5L));
    long tuck_n = tuck_asInt(time.tuck_ms(42L));
    sys.exit(tuck_n);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
