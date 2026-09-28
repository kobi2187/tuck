module _38_division;

import rt = tuck_rt;
import sys = mod_sys;

void tuckˑfnˑmain() {
    long tuckˑvˑq = (7L / 2L);
    double tuckˑvˑr = (7.0 / 2.0);
    long tuckˑvˑbudget = 100L;
    tuckˑvˑbudget = (tuckˑvˑbudget / 8L);
    if ((tuckˑvˑq == 3L)) {
        if ((tuckˑvˑbudget == 12L)) {
            if ((tuckˑvˑr > 3.4)) {
                sys.exit(0L);
            }
        }
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
