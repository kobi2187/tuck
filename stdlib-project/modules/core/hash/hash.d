module hash;

import rt = tuck_rt;
import bits = mod_bits;
import str = mod_str;

ulong tuck_fnvOffsetBasis() {
    return 14695981039346656037UL;
}

ulong tuck_fnvPrime() {
    return 1099511628211L;
}

ulong tuck_fnvStep(ulong acc, ulong octet) {
    ulong tuck_mixed = bits.bitXor(acc, octet);
    return (tuck_mixed * tuck_fnvPrime());
}

ulong tuck_hashStr(string data) {
    ulong tuck_h = tuck_fnvOffsetBasis();
    foreach (tuck_i; 0L .. (cast(long) data.length - 1L) + 1) {
        string tuck_ch = str.charAt(data, tuck_i);
        long tuck_code = str.ord(tuck_ch);
        tuck_h = tuck_fnvStep(tuck_h, cast(ulong)(tuck_code));
    }
    return tuck_h;
}

ulong tuck_combine(ulong a, ulong b) {
    return tuck_fnvStep(a, b);
}

long tuck_main() {
    if ((tuck_hashStr("") != tuck_fnvOffsetBasis())) {
        return 1L;
    }
    ulong tuck_a = tuck_hashStr("hello");
    ulong tuck_b = tuck_hashStr("world");
    if ((tuck_a == tuck_b)) {
        return 2L;
    }
    if ((tuck_a != tuck_hashStr("hello"))) {
        return 3L;
    }
    if ((tuck_hashStr("ab") == tuck_hashStr("ba"))) {
        return 4L;
    }
    return 0L;
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
