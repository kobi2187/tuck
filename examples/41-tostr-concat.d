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
    string tuckˑvˑs = (tuckOwnTmp1 ~ " bottles");
    console.printLine(tuckˑvˑs);
    string tuckOwnTmp2 = str.toStr(tuckˑvˑn);
    string tuckˑvˑt = (tuckOwnTmp2 ~ " more");
    console.printLine(tuckˑvˑt);
    tuckˑtypeˑJar tuckˑvˑj = tuckˑtypeˑJar(count: 7L, label: rt.tuckCopyG("jam"));
    long tuckˑvˑc = tuckˑvˑj.count;
    string tuckOwnTmp3 = (tuckˑvˑj.label ~ ": ");
    string tuckOwnTmp4 = str.toStr(tuckˑvˑc);
    string tuckˑvˑu = (tuckOwnTmp3 ~ tuckOwnTmp4);
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
