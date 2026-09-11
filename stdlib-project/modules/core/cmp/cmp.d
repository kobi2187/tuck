module cmp;

import rt = tuck_rt;

enum tuck_Order { Before, Same, After }

// interface Sortable: no satisfying types

tuck_Order tuck_flipped(tuck_Order o) {
    final switch (o) {
    case tuck_Order.Before:
        return tuck_Order.After;
    case tuck_Order.Same:
        return tuck_Order.Same;
    case tuck_Order.After:
        return tuck_Order.Before;
    }
    return typeof(return).init;
}

tuck_Order tuck_breakTiesWith(tuck_Order o, tuck_Order next) {
    final switch (o) {
    case tuck_Order.Same:
        return next;
    case tuck_Order.Before:
        return tuck_Order.Before;
    case tuck_Order.After:
        return tuck_Order.After;
    }
    return typeof(return).init;
}

bool tuck_isBefore(tuck_Order o) {
    final switch (o) {
    case tuck_Order.Before:
        return true;
    case tuck_Order.Same:
        return false;
    case tuck_Order.After:
        return false;
    }
    return typeof(return).init;
}

T tuck_smaller(T)(T a, T b) {
    if ((a < b)) {
        return a;
    }
    return b;
}

T tuck_larger(T)(T a, T b) {
    if ((a < b)) {
        return b;
    }
    return a;
}

T tuck_clamped(T)(T x, T low, T high) {
    if ((x < low)) {
        return low;
    }
    if ((high < x)) {
        return high;
    }
    return x;
}

long tuck_main() {
    tuck_Order tuck_f = tuck_flipped(tuck_Order.Before);
    tuck_Order tuck_t = tuck_breakTiesWith(tuck_Order.Same, tuck_Order.After);
    if (tuck_isBefore(tuck_f)) {
        return 1L;
    }
    if (tuck_isBefore(tuck_t)) {
        return 2L;
    }
    long tuck_s = tuck_smaller(3L, 9L);
    long tuck_l = tuck_larger(3L, 9L);
    long tuck_c = tuck_clamped(42L, 0L, 10L);
    return (((tuck_s + tuck_l) - tuck_c) - 2L);
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
