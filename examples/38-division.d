module _38_division;

import rt = tuck_rt;
import sys = mod_sys;

void tuck_main() {
    long tuck_q = (7 / 2);
    double tuck_r = (7.0 / 2.0);
    long tuck_budget = 100;
    tuck_budget = (tuck_budget / 8);
    if ((tuck_q == 3)) {
        if ((tuck_budget == 12)) {
            if ((tuck_r > 3.4)) {
                sys.exit(0);
            }
        }
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
