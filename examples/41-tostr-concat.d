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
    string tuckOwnTmp1 = str.toStr(tuckˑvˑn);
    scope(exit) rt.tuckDrop(tuckOwnTmp1);
    string tuckˑvˑs = (tuckOwnTmp1 ~ " bottles");
    scope(exit) rt.tuckDrop(tuckˑvˑs);
    console.printLine(tuckˑvˑs);
    string tuckOwnTmp2 = str.toStr(tuckˑvˑn);
    scope(exit) rt.tuckDrop(tuckOwnTmp2);
    string tuckˑvˑt = (tuckOwnTmp2 ~ " more");
    scope(exit) rt.tuckDrop(tuckˑvˑt);
    console.printLine(tuckˑvˑt);
    tuckˑtypeˑJar tuckˑvˑj = tuckˑtypeˑJar(count: 7L, label: ("jam").idup);
    scope(exit) rt.tuckDrop(tuckˑvˑj.label);
    long tuckˑvˑc = tuckˑvˑj.count;
    string tuckOwnTmp3 = (tuckˑvˑj.label ~ ": ");
    scope(exit) rt.tuckDrop(tuckOwnTmp3);
    string tuckOwnTmp4 = str.toStr(tuckˑvˑc);
    scope(exit) rt.tuckDrop(tuckOwnTmp4);
    string tuckˑvˑu = (tuckOwnTmp3 ~ tuckOwnTmp4);
    scope(exit) rt.tuckDrop(tuckˑvˑu);
    console.printLine(tuckˑvˑu);
    if ((tuckˑvˑs == "99 bottles")) {
        if ((tuckˑvˑu == "jam: 7")) {
            sys.exit(0L);
        }
    }
    sys.exit(1L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
