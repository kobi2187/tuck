module _35_ffi_struct;

import rt = tuck_rt;
import sys = mod_sys;

extern (C) struct Point {
    int x;
    int y;
}

extern (C) int takesPoint(Point p);

extern (C) Point makesPoint(int x, int y);


void tuck_main() {
    Point tuck_p = makesPoint(3, 7);
    int tuck_r = takesPoint(tuck_p);
    if ((tuck_r == 307)) {
        sys.exit(0);
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
