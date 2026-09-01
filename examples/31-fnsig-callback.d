module _31_fnsig_callback;

import rt = tuck_rt;
import sys = mod_sys;

alias tuck_Adder = long function(long a, long b);

struct tuck_Calc {
    tuck_Adder add;
}

long tuck_plus(long a, long b) {
    return (a + b);
}

void tuck_main() {
    tuck_Calc c = tuck_Calc(add: &tuck_plus);
    long r = c.add(40, 2);
    sys.exit(r);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
