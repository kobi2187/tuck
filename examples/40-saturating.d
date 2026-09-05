module _40_saturating;

import rt = tuck_rt;

alias tuck_SafeRPM = ushort;

long tuck_main() {
    tuck_SafeRPM tuck_over = tuck_SafeRPM(rt.tuckSat!(ushort)(cast(ulong)(70000)));
    tuck_SafeRPM tuck_ok = tuck_SafeRPM(rt.tuckSat!(ushort)(cast(ulong)(1200)));
    if ((tuck_over == tuck_SafeRPM(rt.tuckSat!(ushort)(cast(ulong)(65535))))) {
        if ((tuck_ok == tuck_SafeRPM(rt.tuckSat!(ushort)(cast(ulong)(1200))))) {
            return 0;
        }
        return 2;
    }
    return 1;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
