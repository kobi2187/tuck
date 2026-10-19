module _41_tostr_concat;

import rt = tuck_rt;
import tuckˑmodˑconsole = mod_console;
import tuckˑmodˑstr = mod_str;
import tuckˑmodˑsys = mod_sys;

struct tuckˑtypeˑJar {
    long count;
    string label;
}

void tuckˑfnˑmain() {
    long tuckˑvˑn = 99L;
    string tuckOwnTmp1 = tuckˑmodˑstr.toStr(tuckˑvˑn);
    scope(exit) rt.tuckDrop(tuckOwnTmp1);
    string tuckˑvˑs = (tuckOwnTmp1 ~ " bottles");
    scope(exit) rt.tuckDrop(tuckˑvˑs);
    tuckˑmodˑconsole.printLine(tuckˑvˑs);
    string tuckOwnTmp2 = tuckˑmodˑstr.toStr(tuckˑvˑn);
    scope(exit) rt.tuckDrop(tuckOwnTmp2);
    string tuckˑvˑt = (tuckOwnTmp2 ~ " more");
    scope(exit) rt.tuckDrop(tuckˑvˑt);
    tuckˑmodˑconsole.printLine(tuckˑvˑt);
    tuckˑtypeˑJar tuckˑvˑj = tuckˑtypeˑJar(count: 7L, label: ("jam").idup);
    scope(exit) rt.tuckDrop(tuckˑvˑj.label);
    long tuckˑvˑc = tuckˑvˑj.count;
    string tuckOwnTmp3 = (tuckˑvˑj.label ~ ": ");
    scope(exit) rt.tuckDrop(tuckOwnTmp3);
    string tuckOwnTmp4 = tuckˑmodˑstr.toStr(tuckˑvˑc);
    scope(exit) rt.tuckDrop(tuckOwnTmp4);
    string tuckˑvˑu = (tuckOwnTmp3 ~ tuckOwnTmp4);
    scope(exit) rt.tuckDrop(tuckˑvˑu);
    tuckˑmodˑconsole.printLine(tuckˑvˑu);
    if ((tuckˑvˑs == "99 bottles")) {
        if ((tuckˑvˑu == "jam: 7")) {
            tuckˑmodˑsys.exit(0L);
        }
    }
    tuckˑmodˑsys.exit(1L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
