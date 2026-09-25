module _43_literal_payload;

import rt = tuck_rt;
import sys = mod_sys;

long tuck_fn_double(long value) {
    return (value * 2L);
}

long tuck_fn_addTen(long value) {
    return (value + 10L);
}

void tuck_fn_main() {
    long tuck_a = tuck_fn_double(5L);
    long tuck_b = tuck_fn_addTen(tuck_fn_double(10L));
    long tuck_total = (tuck_a + tuck_b);
    sys.exit(tuck_total);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
