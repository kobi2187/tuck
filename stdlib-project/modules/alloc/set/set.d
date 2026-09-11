module set;

import rt = tuck_rt;
import seq = mod_seq;

struct tuck_Set(T) {
    T[] items;
}

bool tuck_has(T)(tuck_Set!(T) s, T value) {
    foreach (tuck_i; 0L .. (cast(long) s.items.length - 1L) + 1) {
        if ((rt.tuckAt(s.items, tuck_i) == value)) {
            return true;
        }
    }
    return false;
}

long tuck_count(T)(tuck_Set!(T) s) {
    return cast(long) s.items.length;
}

T[] tuck_toSeq(T)(tuck_Set!(T) s) {
    return s.items;
}

tuck_Set!(T) tuck_add(T)(tuck_Set!(T) s, T value) {
    s.items = s.items.dup;
    return tuck_add_moved(s, value);
}

tuck_Set!(T) tuck_add_moved(T)(tuck_Set!(T) s, T value) {
    if (tuck_has(s, value)) {
        return s;
    }
    T[] tuck_xs = s.items;
    tuck_xs ~= value;
    return tuck_Set!(T)(items: tuck_xs);
}

tuck_Set!(T) tuck_remove(T)(tuck_Set!(T) s, T value) {
    s.items = s.items.dup;
    return tuck_remove_moved(s, value);
}

tuck_Set!(T) tuck_remove_moved(T)(tuck_Set!(T) s, T value) {
    T[] tuck_kept = [];
    foreach (tuck_i; 0L .. (cast(long) s.items.length - 1L) + 1) {
        T tuck_item = rt.tuckAt(s.items, tuck_i);
        if ((tuck_item != value)) {
            tuck_kept ~= tuck_item;
        }
    }
    return tuck_Set!(T)(items: tuck_kept);
}

tuck_Set!(T) tuck_union(T)(tuck_Set!(T) a, tuck_Set!(T) b) {
    a.items = a.items.dup;
    return tuck_union_moved(a, b);
}

tuck_Set!(T) tuck_union_moved(T)(tuck_Set!(T) a, tuck_Set!(T) b) {
    tuck_Set!(T) tuck_out = a;
    foreach (tuck_i; 0L .. (cast(long) b.items.length - 1L) + 1) {
        tuck_out = tuck_add_moved(tuck_out, rt.tuckAt(b.items, tuck_i));
    }
    return tuck_out;
}

tuck_Set!(T) tuck_intersect(T)(tuck_Set!(T) a, tuck_Set!(T) b) {
    a.items = a.items.dup;
    return tuck_intersect_moved(a, b);
}

tuck_Set!(T) tuck_intersect_moved(T)(tuck_Set!(T) a, tuck_Set!(T) b) {
    tuck_Set!(T) tuck_out = tuck_Set!(T)(items: []);
    foreach (tuck_i; 0L .. (cast(long) a.items.length - 1L) + 1) {
        T tuck_item = rt.tuckAt(a.items, tuck_i);
        if (tuck_has(b, tuck_item)) {
            tuck_out = tuck_add_moved(tuck_out, tuck_item);
        }
    }
    return tuck_out;
}

tuck_Set!(T) tuck_difference(T)(tuck_Set!(T) a, tuck_Set!(T) b) {
    a.items = a.items.dup;
    return tuck_difference_moved(a, b);
}

tuck_Set!(T) tuck_difference_moved(T)(tuck_Set!(T) a, tuck_Set!(T) b) {
    tuck_Set!(T) tuck_out = tuck_Set!(T)(items: []);
    foreach (tuck_i; 0L .. (cast(long) a.items.length - 1L) + 1) {
        T tuck_item = rt.tuckAt(a.items, tuck_i);
        if (!tuck_has(b, tuck_item)) {
            tuck_out = tuck_add_moved(tuck_out, tuck_item);
        }
    }
    return tuck_out;
}

tuck_Set!(string) tuck_threeWords() {
    tuck_Set!(string) tuck_s = tuck_Set!(string)(items: []);
    tuck_s = tuck_add_moved(tuck_s, "a");
    tuck_s = tuck_add_moved(tuck_s, "b");
    return tuck_add(tuck_s, "c");
}

long tuck_checkBasics() {
    tuck_Set!(string) tuck_s = tuck_Set!(string)(items: []);
    tuck_s = tuck_add_moved(tuck_s, "a");
    tuck_s = tuck_add_moved(tuck_s, "a");
    if ((tuck_count(tuck_s) != 1L)) {
        return 1L;
    }
    if (!tuck_has(tuck_s, "a")) {
        return 2L;
    }
    if (tuck_has(tuck_s, "z")) {
        return 3L;
    }
    return tuck_checkRemove();
}

long tuck_checkRemove() {
    tuck_Set!(string) tuck_s = tuck_threeWords();
    if ((tuck_count(tuck_s) != 3L)) {
        return 4L;
    }
    tuck_s = tuck_remove_moved(tuck_s, "b");
    if ((tuck_count(tuck_s) != 2L)) {
        return 5L;
    }
    if (tuck_has(tuck_s, "b")) {
        return 6L;
    }
    tuck_s = tuck_remove_moved(tuck_s, "zzz");
    if ((tuck_count(tuck_s) != 2L)) {
        return 7L;
    }
    return 0L;
}

tuck_Set!(string) tuck_twoOnly() {
    tuck_Set!(string) tuck_t = tuck_Set!(string)(items: []);
    tuck_t = tuck_add_moved(tuck_t, "b");
    return tuck_add(tuck_t, "d");
}

long tuck_checkAlgebra() {
    tuck_Set!(string) tuck_a = tuck_threeWords();
    tuck_Set!(string) tuck_b = tuck_twoOnly();
    tuck_Set!(string) tuck_both = tuck_union(tuck_a, tuck_b);
    if ((tuck_count(tuck_both) != 4L)) {
        return 8L;
    }
    tuck_Set!(string) tuck_common = tuck_intersect(tuck_a, tuck_b);
    if ((tuck_count(tuck_common) != 1L)) {
        return 9L;
    }
    if (!tuck_has(tuck_common, "b")) {
        return 10L;
    }
    return tuck_checkDifference(tuck_a, tuck_b);
}

long tuck_checkDifference(tuck_Set!(string) a, tuck_Set!(string) b) {
    tuck_Set!(string) tuck_only = tuck_difference(a, b);
    if ((tuck_count(tuck_only) != 2L)) {
        return 11L;
    }
    if (tuck_has(tuck_only, "b")) {
        return 12L;
    }
    if (!tuck_has(tuck_only, "a")) {
        return 13L;
    }
    tuck_Set!(string) tuck_other = tuck_difference(b, a);
    if ((tuck_count(tuck_other) != 1L)) {
        return 14L;
    }
    string[] tuck_seq = (tuck_toSeq(tuck_other)).dup;
    if ((cast(long) tuck_seq.length != 1L)) {
        return 15L;
    }
    return 0L;
}

long tuck_main() {
    long tuck_basics = tuck_checkBasics();
    if ((tuck_basics != 0L)) {
        return tuck_basics;
    }
    return tuck_checkAlgebra();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
