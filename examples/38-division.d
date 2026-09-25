module _38_division;

import rt = tuck_rt;
import sys = mod_sys;

void tuck_fn_main() {
    long tuck_q = (7L / 2L);
    double tuck_r = (7.0 / 2.0);
    long tuck_budget = 100L;
    tuck_budget = (tuck_budget / 8L);
    if ((tuck_q == 3L)) {
        if ((tuck_budget == 12L)) {
            if ((tuck_r > 3.4)) {
                sys.exit(0L);
            }
        }
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
