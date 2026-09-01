module _38_division;

import rt = tuck_rt;
import sys = mod_sys;

void tuck_main() {
    long q = (7 / 2);
    double r = (7.0 / 2.0);
    long budget = 100;
    budget = (budget / 8);
    if ((q == 3)) {
        if ((budget == 12)) {
            if ((r > 3.4)) {
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
