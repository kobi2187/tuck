module _41_tostr_concat;

import rt = tuck_rt;
import sys = mod_sys;
import str = mod_str;
import console = mod_console;

struct tuck_Jar {
    long count;
    string label;
}

void tuck_main() {
    long tuck_n = 99;
    string tuck_s = (str.toStr(tuck_n) ~ " bottles");
    console.printLine(tuck_s);
    string tuck_t = (str.toStr(tuck_n) ~ " more");
    console.printLine(tuck_t);
    tuck_Jar tuck_j = tuck_Jar(count: 7, label: "jam");
    long tuck_c = tuck_j.count;
    string tuck_u = ((tuck_j.label ~ ": ") ~ str.toStr(tuck_c));
    console.printLine(tuck_u);
    if ((tuck_s == "99 bottles")) {
        if ((tuck_u == "jam: 7")) {
            sys.exit(0);
        }
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
