module _33_ffi_zlib;

import rt = tuck_rt;
pragma(lib, "z");
import sys = mod_sys;

extern (C) ulong compressBound(ulong sourceLen);


void tuck_fn_main() {
    ulong tuck_b = compressBound(1000L);
    if ((tuck_b == 1013L)) {
        sys.exit(0L);
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
