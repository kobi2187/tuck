module _34_ffi_cstring;

import rt = tuck_rt;
pragma(lib, "z");
import sys = mod_sys;
import console = mod_console;
import zlib_shim;

string zlibVersion() {
    return zlib_shim.zlibVersion();
}


extern (C) ulong compressBound(ulong sourceLen);


void tuckˑfnˑmain() {
    string tuckˑvˑv = zlibVersion();
    console.printLine(tuckˑvˑv);
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
