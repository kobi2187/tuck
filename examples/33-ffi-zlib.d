module _33_ffi_zlib;

import rt = tuck_rt;
pragma(lib, "z");
import tuckˑmodˑsys = mod_sys;

extern (C) ulong compressBound(ulong sourceLen);


void tuckˑfnˑmain() {
    ulong tuckˑvˑb = compressBound(1000L);
    if ((tuckˑvˑb == 1013L)) {
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
