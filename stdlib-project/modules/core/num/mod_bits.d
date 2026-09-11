module mod_bits;

import rt = tuck_rt;

ulong bitAnd(ulong a, ulong b) {
    return rt.bitAnd(a, b);
}

ulong bitOr(ulong a, ulong b) {
    return rt.bitOr(a, b);
}

ulong bitXor(ulong a, ulong b) {
    return rt.bitXor(a, b);
}

ulong bitNot(ulong a) {
    return rt.bitNot(a);
}

ulong shiftLeft(ulong a, long by) {
    return rt.shiftLeft(a, by);
}

ulong shiftRight(ulong a, long by) {
    return rt.shiftRight(a, by);
}


