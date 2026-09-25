module _41_tostr_concat;

import rt = tuck_rt;
import sys = mod_sys;
import str = mod_str;
import console = mod_console;

struct tuck_type_Jar {
    long count;
    string label;
}

void tuck_fn_main() {
    long tuck_n = 99L;
    string tuck_s = (str.toStr(tuck_n) ~ " bottles");
    console.printLine(tuck_s);
    string tuck_t = (str.toStr(tuck_n) ~ " more");
    console.printLine(tuck_t);
    tuck_type_Jar tuck_j = tuck_type_Jar(count: 7L, label: "jam");
    long tuck_c = tuck_j.count;
    string tuck_u = ((tuck_j.label ~ ": ") ~ str.toStr(tuck_c));
    console.printLine(tuck_u);
    if ((tuck_s == "99 bottles")) {
        if ((tuck_u == "jam: 7")) {
            sys.exit(0L);
        }
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
