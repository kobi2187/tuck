module _38_division;

import rt = tuck_rt;
import tuckˑmodˑsys = mod_sys;

void tuckˑfnˑmain() {
    long tuckˑvˑq = (7L / 2L);
    double tuckˑvˑr = (7.0 / 2.0);
    long tuckˑvˑbudget = 100L;
    tuckˑvˑbudget = (tuckˑvˑbudget / 8L);
    if ((tuckˑvˑq == 3L)) {
        if ((tuckˑvˑbudget == 12L)) {
            if ((tuckˑvˑr > 3.4)) {
                tuckˑmodˑsys.exit(0L);
            }
        }
    }
    tuckˑmodˑsys.exit(1L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
