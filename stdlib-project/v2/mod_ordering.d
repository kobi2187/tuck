module mod_ordering;

import value = mod_value;

value.tuck_Order tuck_compare(T)(T self, T other) {
    if ((self < other)) {
        return value.tuck_Order.Before;
    }
    if ((self > other)) {
        return value.tuck_Order.After;
    }
    return value.tuck_Order.Same;
}

bool tuck_equals(T)(T self, T other) {
    return (self == other);
}

T tuck_minOf(T)(T a, T b) {
    value.tuck_Order tuck_c = tuck_compare(a, b);
    switch (tuck_c) {
    case value.tuck_Order.After:
        return b;
    default:
        return a;
    }
    return typeof(return).init;
}

T tuck_maxOf(T)(T a, T b) {
    value.tuck_Order tuck_c = tuck_compare(a, b);
    switch (tuck_c) {
    case value.tuck_Order.Before:
        return b;
    default:
        return a;
    }
    return typeof(return).init;
}

T tuck_clamped(T)(T value, T low, T high) {
    T tuck_lifted = tuck_maxOf(value, low);
    return tuck_minOf(tuck_lifted, high);
}

bool tuck_isBefore(T)(T a, T b) {
    value.tuck_Order tuck_c = tuck_compare(a, b);
    switch (tuck_c) {
    case value.tuck_Order.Before:
        return true;
    default:
        return false;
    }
    return typeof(return).init;
}

bool tuck_isAfter(T)(T a, T b) {
    value.tuck_Order tuck_c = tuck_compare(a, b);
    switch (tuck_c) {
    case value.tuck_Order.After:
        return true;
    default:
        return false;
    }
    return typeof(return).init;
}

bool tuck_isSame(T)(T a, T b) {
    value.tuck_Order tuck_c = tuck_compare(a, b);
    switch (tuck_c) {
    case value.tuck_Order.Same:
        return true;
    default:
        return false;
    }
    return typeof(return).init;
}

value.tuck_Order tuck_flipped(value.tuck_Order o) {
    final switch (o) {
    case value.tuck_Order.Before:
        return value.tuck_Order.After;
    case value.tuck_Order.Same:
        return value.tuck_Order.Same;
    case value.tuck_Order.After:
        return value.tuck_Order.Before;
    }
    return typeof(return).init;
}

value.tuck_Order tuck_breakTiesWith(value.tuck_Order o, value.tuck_Order next) {
    final switch (o) {
    case value.tuck_Order.Same:
        return next;
    case value.tuck_Order.Before:
        return value.tuck_Order.Before;
    case value.tuck_Order.After:
        return value.tuck_Order.After;
    }
    return typeof(return).init;
}

