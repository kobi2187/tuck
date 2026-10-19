module _35_ffi_struct;

import rt = tuck_rt;
import tuckˑmodˑsys = mod_sys;

extern (C) struct Point {
    int x;
    int y;
}

extern (C) int takesPoint(Point p);

extern (C) Point makesPoint(int x, int y);


void tuckˑfnˑmain() {
    Point tuckˑvˑp = makesPoint(cast(int)3, cast(int)7);
    int tuckˑvˑr = takesPoint(tuckˑvˑp);
    if ((tuckˑvˑr == cast(int)307)) {
        tuckˑmodˑsys.exit(0L);
    }
    tuckˑmodˑsys.exit(1L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
