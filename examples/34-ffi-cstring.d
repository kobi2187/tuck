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


void tuck_main() {
    string v = zlibVersion();
    console.printLine(v);
    ulong b = compressBound(1000);
    if ((b == 1013)) {
        sys.exit(0);
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
