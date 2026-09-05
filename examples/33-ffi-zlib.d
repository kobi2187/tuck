module _33_ffi_zlib;

import rt = tuck_rt;
pragma(lib, "z");
import sys = mod_sys;

extern (C) ulong compressBound(ulong sourceLen);


void tuck_main() {
    ulong tuck_b = compressBound(1000);
    if ((tuck_b == 1013)) {
        sys.exit(0);
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
