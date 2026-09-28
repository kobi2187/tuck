module _36_ffi_enum_callback;

import rt = tuck_rt;
import sys = mod_sys;

alias tuckˑfnsigˑBinOp = extern (C) int function(int a, int b);

extern (C) enum Op { OP_ADD = 10, OP_MUL = 20, OP_NEG = 30 }

extern (C) int applyOp(Op op, int a, int b);

extern (C) int callBack(tuckˑfnsigˑBinOp cb, int a, int b);


extern (C) int tuckˑfnˑaddTwo(int a, int b) {
    return (a + b);
}

void tuckˑfnˑmain() {
    int tuckˑvˑm = applyOp(Op.OP_MUL, 6L, 7L);
    int tuckˑvˑc = callBack(&tuckˑfnˑaddTwo, 40L, 2L);
    if ((tuckˑvˑm == 42L)) {
        if ((tuckˑvˑc == 1042L)) {
            sys.exit(0L);
        }
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuckˑfnˑmain();
}
