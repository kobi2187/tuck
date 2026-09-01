module _36_ffi_enum_callback;

import rt = tuck_rt;
import sys = mod_sys;

alias tuck_BinOp = extern (C) int function(int a, int b);

extern (C) enum Op { OP_ADD = 10, OP_MUL = 20, OP_NEG = 30 }

extern (C) int applyOp(Op op, int a, int b);

extern (C) int callBack(tuck_BinOp cb, int a, int b);


extern (C) int tuck_addTwo(int a, int b) {
    return (a + b);
}

void tuck_main() {
    int m = applyOp(Op.OP_MUL, 6, 7);
    int c = callBack(&tuck_addTwo, 40, 2);
    if ((m == 42)) {
        if ((c == 1042)) {
            sys.exit(0);
        }
    }
    sys.exit(1);
}

void main(string[] args) {
    rt.tuckSetArgs(args);
    tuck_main();
}
