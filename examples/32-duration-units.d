module _32_duration_units;

import rt = tuck_rt;
import sys = mod_sys;
import time = mod_time;

struct TRec_ok_64D7 {
    bool ok;
}

long tuck_asInt(time.tuck_Milliseconds d) {
    return 42;
}

TRec_ok_64D7 tuck_budget(time.tuck_Milliseconds d) {
    return TRec_ok_64D7(ok: true);
}

void tuck_main() {
    TRec_ok_64D7 r = tuck_budget(time.tuck_ms(5));
    long n = tuck_asInt(time.tuck_ms(42));
    sys.exit(n);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
