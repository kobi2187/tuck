module _31_fnsig_callback;

import rt = tuck_rt;
import sys = mod_sys;

alias tuckˑfnsigˑAdder = long function(long a, long b);

struct tuckˑtypeˑCalc {
    tuckˑfnsigˑAdder add;
}

long tuckˑfnˑplus(long a, long b) {
    return (a + b);
}

void tuckˑfnˑmain() {
    tuckˑtypeˑCalc tuckˑvˑc = tuckˑtypeˑCalc(add: &tuckˑfnˑplus);
    long tuckˑvˑr = tuckˑvˑc.add(40L, 2L);
    sys.exit(tuckˑvˑr);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
