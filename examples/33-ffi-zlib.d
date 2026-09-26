module _33_ffi_zlib;

import rt = tuck_rt;
pragma(lib, "z");
import sys = mod_sys;

extern (C) ulong compressBound(ulong sourceLen);


void tuckˑfnˑmain() {
    ulong tuckˑvˑb = compressBound(1000L);
    if ((tuckˑvˑb == 1013L)) {
        sys.exit(0L);
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
