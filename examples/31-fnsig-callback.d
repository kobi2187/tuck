module _31_fnsig_callback;

import rt = tuck_rt;
import sys = mod_sys;

alias tuck_type_Adder = long function(long a, long b);

struct tuck_type_Calc {
    tuck_type_Adder add;
}

long tuck_fn_plus(long a, long b) {
    return (a + b);
}

void tuck_fn_main() {
    tuck_type_Calc tuck_c = tuck_type_Calc(add: &tuck_fn_plus);
    long tuck_r = tuck_c.add(40L, 2L);
    sys.exit(tuck_r);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
