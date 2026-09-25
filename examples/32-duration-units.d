module _32_duration_units;

import rt = tuck_rt;
import sys = mod_sys;
import time = mod_time;

struct TRec_ok(T_ok) {
    T_ok ok;
}

long tuck_fn_asInt(time.tuck_type_Milliseconds d) {
    return 42L;
}

TRec_ok!(bool) tuck_fn_budget(time.tuck_type_Milliseconds d) {
    return TRec_ok!(bool)(ok: true);
}

void tuck_fn_main() {
    TRec_ok!(bool) tuck_r = tuck_fn_budget(time.tuck_fn_ms(5L));
    long tuck_n = tuck_fn_asInt(time.tuck_fn_ms(42L));
    sys.exit(tuck_n);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
