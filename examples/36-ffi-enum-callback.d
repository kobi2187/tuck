module _36_ffi_enum_callback;

import rt = tuck_rt;
import sys = mod_sys;

alias tuck_type_BinOp = extern (C) int function(int a, int b);

extern (C) enum Op { OP_ADD = 10, OP_MUL = 20, OP_NEG = 30 }

extern (C) int applyOp(Op op, int a, int b);

extern (C) int callBack(tuck_type_BinOp cb, int a, int b);


extern (C) int tuck_fn_addTwo(int a, int b) {
    return (a + b);
}

void tuck_fn_main() {
    int tuck_m = applyOp(Op.OP_MUL, 6L, 7L);
    int tuck_c = callBack(&tuck_fn_addTwo, 40L, 2L);
    if ((tuck_m == 42L)) {
        if ((tuck_c == 1042L)) {
            sys.exit(0L);
        }
    }
    sys.exit(1L);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_fn_main();
}
