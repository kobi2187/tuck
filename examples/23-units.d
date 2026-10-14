module _23_units;

import rt = tuck_rt;

struct TRec_done(T_done) {
    T_done done;
}

alias tuckˑtypeˑMilliseconds = uint;

tuckˑtypeˑMilliseconds tuckˑfnˑms(uint value) {
    return tuckˑtypeˑMilliseconds(value);
}

TRec_done!(bool) tuckˑfnˑdelay(tuckˑtypeˑMilliseconds ms) {
    return TRec_done!(bool)(done: true);
}

void tuckˑfnˑmain() {
    TRec_done!(bool) tuckˑvˑr = tuckˑfnˑdelay(tuckˑfnˑms(cast(uint)5));
    return;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    rt.tuckLeakMark();
    tuckˑfnˑmain();
    return rt.tuckLeakCheck(0);
}
