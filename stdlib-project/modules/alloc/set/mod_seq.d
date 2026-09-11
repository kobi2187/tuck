module mod_seq;

import rt = tuck_rt;

T at(T)(T[] items, long index) {
    return rt.at(items, index);
}

void setAt(T)(T[] items, long index, T value) {
    rt.setAt(items, index, value);
}

T[] push(T)(T[] items, T value) {
    return rt.push(items, value);
}

long count(T)(T[] items) {
    return rt.count(items);
}


