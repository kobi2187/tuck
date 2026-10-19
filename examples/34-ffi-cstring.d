module _34_ffi_cstring;

import rt = tuck_rt;
pragma(lib, "z");
import tuckˑmodˑconsole = mod_console;
import tuckˑmodˑsys = mod_sys;
import zlib_shim;

string zlibVersion() {
    return zlib_shim.zlibVersion();
}


extern (C) ulong compressBound(ulong sourceLen);


void tuckˑfnˑmain() {
    string tuckˑvˑv = zlibVersion();
    scope(exit) rt.tuckDrop(tuckˑvˑv);
    tuckˑmodˑconsole.printLine(tuckˑvˑv);
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
