module _43_literal_payload;

import rt = tuck_rt;
import sys = mod_sys;

long tuck_double(long value) {
    return (value * 2);
}

long tuck_addTen(long value) {
    return (value + 10);
}

void tuck_main() {
    long tuck_a = tuck_double(5);
    long tuck_b = tuck_addTen(tuck_double(10));
    long tuck_total = (tuck_a + tuck_b);
    sys.exit(tuck_total);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
