module _43_literal_payload;

import rt = tuck_rt;
import sys = mod_sys;

long tuckˑfnˑdouble(long value) {
    return (value * 2L);
}

long tuckˑfnˑaddTen(long value) {
    return (value + 10L);
}

void tuckˑfnˑmain() {
    long tuckˑvˑa = tuckˑfnˑdouble(5L);
    long tuckˑvˑb = tuckˑfnˑaddTen(tuckˑfnˑdouble(10L));
    long tuckˑvˑtotal = (tuckˑvˑa + tuckˑvˑb);
    sys.exit(tuckˑvˑtotal);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
