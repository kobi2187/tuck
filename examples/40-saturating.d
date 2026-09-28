module _40_saturating;

import rt = tuck_rt;

alias tuckˑtypeˑSafeRPM = ushort;

long tuckˑfnˑmain() {
    tuckˑtypeˑSafeRPM tuckˑvˑover = tuckˑtypeˑSafeRPM(rt.tuckSat!(ushort)(cast(ulong)(70000L)));
    tuckˑtypeˑSafeRPM tuckˑvˑok = tuckˑtypeˑSafeRPM(rt.tuckSat!(ushort)(cast(ulong)(1200L)));
    if ((tuckˑvˑover == tuckˑtypeˑSafeRPM(rt.tuckSat!(ushort)(cast(ulong)(65535L))))) {
        if ((tuckˑvˑok == tuckˑtypeˑSafeRPM(rt.tuckSat!(ushort)(cast(ulong)(1200L))))) {
            return 0L;
        }
        return 2L;
    }
    return 1L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuckˑfnˑmain();
    return cast(int) mainRc;
}
