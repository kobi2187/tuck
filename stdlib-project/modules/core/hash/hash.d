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

ulong tuck_hashBytes(ubyte[] data) {
    ulong tuck_h = tuck_fnvOffsetBasis();
    foreach (tuck_i; 0L .. (cast(long) data.length - 1L) + 1) {
        ulong tuck_octet = cast(ulong)(rt.tuckAt(data, tuck_i));
        tuck_h = tuck_fnvStep(tuck_h, tuck_octet);
    }
    return tuck_h;
}

ubyte[] tuck_strBytes(string t) {
    ubyte[] tuck_out = [];
    foreach (tuck_i; 0L .. (str.byteCount(t) - 1L) + 1) {
        ubyte tuck_b = str.byteAt(t, tuck_i);
        tuck_out ~= tuck_b;
    }
    return tuck_out;
}

ulong tuck_hashStr(string data) {
    ubyte[] tuck_bytes = (tuck_strBytes(data)).dup;
    return tuck_hashBytes(tuck_bytes);
}

ubyte[] tuck_u64Bytes(ulong x) {
    ubyte[] tuck_out = [];
    long tuck_i = 0L;
    while ((tuck_i < 8L)) {
        ulong tuck_shifted = bits.shiftRight(x, (tuck_i * 8L));
        ulong tuck_octet = bits.bitAnd(tuck_shifted, 255L);
        ubyte tuck_b = cast(ubyte)(tuck_octet);
        tuck_out ~= tuck_b;
        tuck_i = (tuck_i + 1L);
    }
    return tuck_out;
}

ulong tuck_hashU64(ulong x) {
    ubyte[] tuck_bytes = (tuck_u64Bytes(x)).dup;
    return tuck_hashBytes(tuck_bytes);
}

ulong tuck_combine(ulong a, ulong b) {
    return tuck_fnvStep(a, b);
}

long tuck_checkHashBytes() {
    ubyte[] tuck_empty = [];
    if ((tuck_hashBytes(tuck_empty) != tuck_fnvOffsetBasis())) {
        return 5L;
    }
    return 0L;
}

long tuck_checkHashU64() {
    if ((tuck_hashU64(0L) != tuck_hashU64(0L))) {
        return 10L;
    }
    ulong tuck_a = tuck_hashU64(1L);
    ulong tuck_b = tuck_hashU64(2L);
    if ((tuck_a == tuck_b)) {
        return 11L;
    }
    if ((tuck_a != tuck_hashU64(1L))) {
        return 12L;
    }
    if ((tuck_hashU64(1L) == tuck_hashU64(256L))) {
        return 13L;
    }
    return 0L;
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
    long tuck_bytes = tuck_checkHashBytes();
    if ((tuck_bytes != 0L)) {
        return tuck_bytes;
    }
    return tuck_checkHashU64();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
