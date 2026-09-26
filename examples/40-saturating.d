module _40_saturating;

import rt = tuck_rt;

alias tuck_type_SafeRPM = ushort;

long tuck_fn_main() {
    tuck_type_SafeRPM tuck_over = tuck_type_SafeRPM(rt.tuckSat!(ushort)(cast(ulong)(70000L)));
    tuck_type_SafeRPM tuck_ok = tuck_type_SafeRPM(rt.tuckSat!(ushort)(cast(ulong)(1200L)));
    if ((tuck_over == tuck_type_SafeRPM(rt.tuckSat!(ushort)(cast(ulong)(65535L))))) {
        if ((tuck_ok == tuck_type_SafeRPM(rt.tuckSat!(ushort)(cast(ulong)(1200L))))) {
            return 0L;
        }
        return 2L;
    }
    return 1L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_fn_main();
    return cast(int) mainRc;
}
