module _41_tostr_concat;

import rt = tuck_rt;
import sys = mod_sys;
import str = mod_str;
import console = mod_console;

struct tuckˑtypeˑJar {
    long count;
    string label;
}

void tuckˑfnˑmain() {
    long tuckˑvˑn = 99L;
    string tuckˑvˑs = (str.toStr(tuckˑvˑn) ~ " bottles");
    console.printLine(tuckˑvˑs);
    string tuckˑvˑt = (str.toStr(tuckˑvˑn) ~ " more");
    console.printLine(tuckˑvˑt);
    tuckˑtypeˑJar tuckˑvˑj = tuckˑtypeˑJar(count: 7L, label: "jam");
    long tuckˑvˑc = tuckˑvˑj.count;
    string tuckˑvˑu = ((tuckˑvˑj.label ~ ": ") ~ str.toStr(tuckˑvˑc));
    console.printLine(tuckˑvˑu);
    if ((tuckˑvˑs == "99 bottles")) {
        if ((tuckˑvˑu == "jam: 7")) {
            sys.exit(0L);
        }
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
