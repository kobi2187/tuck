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
    long n = 99;
    string s = (str.toStr(n) ~ " bottles");
    console.printLine(s);
    string t = (str.toStr(n) ~ " more");
    console.printLine(t);
    tuck_Jar j = tuck_Jar(count: 7, label: "jam");
    long c = j.count;
    string u = ((j.label ~ ": ") ~ str.toStr(c));
    console.printLine(u);
    if ((s == "99 bottles")) {
        if ((u == "jam: 7")) {
            sys.exit(0);
        }
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
