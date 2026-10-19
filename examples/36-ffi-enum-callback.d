module _36_ffi_enum_callback;

import rt = tuck_rt;
import tuckˑmodˑsys = mod_sys;

alias tuckˑfnsigˑBinOp = extern (C) int function(int a, int b);

extern (C) enum Op { OP_ADD = 10, OP_MUL = 20, OP_NEG = 30 }

extern (C) int applyOp(Op op, int a, int b);

extern (C) int callBack(tuckˑfnsigˑBinOp cb, int a, int b);


extern (C) int tuckˑfnˑaddTwo(int a, int b) {
    return rt.tuckArith!(int, rt.OvOp.Add, rt.OvPolicy.Trap)(a, b);
}

void tuckˑfnˑmain() {
    int tuckˑvˑm = applyOp(Op.OP_MUL, cast(int)6, cast(int)7);
    int tuckˑvˑc = callBack(&tuckˑfnˑaddTwo, cast(int)40, cast(int)2);
    if ((tuckˑvˑm == cast(int)42)) {
        if ((tuckˑvˑc == cast(int)1042)) {
            tuckˑmodˑsys.exit(0L);
        }
    }
    tuckˑmodˑsys.exit(1L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
