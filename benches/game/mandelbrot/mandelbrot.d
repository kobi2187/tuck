module mandelbrot;

import rt = tuck_rt;
import tuckˑmodˑcli = mod_cli;
import tuckˑmodˑconsole = mod_console;
import tuckˑmodˑconvert = mod_convert;
import tuckˑmodˑstr = mod_str;

enum tuckˑconstˑLimit = 50L;

bool tuckˑfnˑinside(double cr, double ci) {
    double tuckˑvˑzr = 0.0;
    double tuckˑvˑzi = 0.0;
    foreach (tuckˑvˑk; 0L .. tuckˑconstˑLimit) {
        double tuckˑvˑnr = (((tuckˑvˑzr * tuckˑvˑzr) - (tuckˑvˑzi * tuckˑvˑzi)) + cr);
        tuckˑvˑzi = (((2.0 * tuckˑvˑzr) * tuckˑvˑzi) + ci);
        tuckˑvˑzr = tuckˑvˑnr;
        if ((((tuckˑvˑzr * tuckˑvˑzr) + (tuckˑvˑzi * tuckˑvˑzi)) > 4.0)) {
            return false;
        }
    }
    return true;
}

long tuckˑfnˑcountInside(long n) {
    long tuckˑvˑcount = 0L;
    foreach (tuckˑvˑy; 0L .. n) {
        foreach (tuckˑvˑx; 0L .. n) {
            double tuckˑvˑcr = (((2.0 * cast(double)(tuckˑvˑx)) / cast(double)(n)) - 1.5);
            double tuckˑvˑci = (((2.0 * cast(double)(tuckˑvˑy)) / cast(double)(n)) - 1.0);
            if (tuckˑfnˑinside(tuckˑvˑcr, tuckˑvˑci)) {
                tuckˑvˑcount = (tuckˑvˑcount + 1L);
            }
        }
    }
    return tuckˑvˑcount;
}

long tuckˑfnˑproblemSize(string[] argv) {
    if ((cast(long) argv.length > 0L)) {
        rt.TuckResult!(long) tuckˑvˑn = tuckˑmodˑconvert.tuckˑfnˑparseInt(rt.tuckAt(argv, 0L));
        if ((tuckˑvˑn.status == rt.TuckStatus.Ok)) {
            return cast(long)(tuckˑvˑn.value);
        }
    }
    return 200L;
}

long tuckˑfnˑmain() {
    string[] tuckˑvˑargv = tuckˑmodˑcli.tuckˑfnˑcommandLine();
    scope(exit) rt.tuckDrop(tuckˑvˑargv);
    long tuckˑvˑn = tuckˑfnˑproblemSize(tuckˑvˑargv);
    long tuckˑvˑc = tuckˑfnˑcountInside(tuckˑvˑn);
    string tuckOwnTmp36 = tuckˑmodˑstr.toStr(tuckˑvˑc);
    scope(exit) rt.tuckDrop(tuckOwnTmp36);
    tuckˑmodˑconsole.printLine(tuckOwnTmp36);
    return 0L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    auto mainRc = tuckˑfnˑmain();
    return rt.tuckLeakCheck(cast(int) mainRc);
}
