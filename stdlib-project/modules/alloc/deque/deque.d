module deque;

import rt = tuck_rt;

struct TRec_rest_value(T_rest, T_value) {
    T_rest rest;
    T_value value;
}

struct tuck_Ring(T) {
    T[] items;
}

long tuck_count(T)(tuck_Ring!(T) r) {
    return cast(long) r.items.length;
}

bool tuck_isEmpty(T)(tuck_Ring!(T) r) {
    return (cast(long) r.items.length == 0L);
}

rt.TuckResult!(T) tuck_first(T)(tuck_Ring!(T) r) {
    if ((cast(long) r.items.length == 0L)) {
        return rt.tnone!(T)();
    }
    return rt.tok(rt.tuckAt(r.items, 0L));
}

rt.TuckResult!(T) tuck_last(T)(tuck_Ring!(T) r) {
    if ((cast(long) r.items.length == 0L)) {
        return rt.tnone!(T)();
    }
    return rt.tok(rt.tuckAt(r.items, (cast(long) r.items.length - 1L)));
}

tuck_Ring!(T) tuck_pushBack(T)(tuck_Ring!(T) r, T value) {
    r.items = r.items.dup;
    return tuck_pushBack_moved(r, value);
}

tuck_Ring!(T) tuck_pushBack_moved(T)(tuck_Ring!(T) r, T value) {
    T[] tuck_xs = r.items;
    tuck_xs ~= value;
    return tuck_Ring!(T)(items: tuck_xs);
}

tuck_Ring!(T) tuck_pushFront(T)(tuck_Ring!(T) r, T value) {
    r.items = r.items.dup;
    return tuck_pushFront_moved(r, value);
}

tuck_Ring!(T) tuck_pushFront_moved(T)(tuck_Ring!(T) r, T value) {
    T[] tuck_xs = [];
    tuck_xs ~= value;
    foreach (tuck_i; 0L .. (cast(long) r.items.length - 1L) + 1) {
        tuck_xs ~= rt.tuckAt(r.items, tuck_i);
    }
    return tuck_Ring!(T)(items: tuck_xs);
}

rt.TuckResult!(TRec_rest_value!(tuck_Ring!(T), T)) tuck_popBack(T)(tuck_Ring!(T) r) {
    long tuck_n = cast(long) r.items.length;
    if ((tuck_n == 0L)) {
        return rt.tnone!(TRec_rest_value!(tuck_Ring!(T), T))();
    }
    T tuck_top = rt.tuckAt(r.items, (tuck_n - 1L));
    T[] tuck_xs = [];
    foreach (tuck_i; 0L .. (tuck_n - 2L) + 1) {
        tuck_xs ~= rt.tuckAt(r.items, tuck_i);
    }
    tuck_Ring!(T) tuck_rest = tuck_Ring!(T)(items: tuck_xs);
    return rt.tok(TRec_rest_value!(tuck_Ring!(T), T)(rest: tuck_rest, value: tuck_top));
}

rt.TuckResult!(TRec_rest_value!(tuck_Ring!(T), T)) tuck_popFront(T)(tuck_Ring!(T) r) {
    long tuck_n = cast(long) r.items.length;
    if ((tuck_n == 0L)) {
        return rt.tnone!(TRec_rest_value!(tuck_Ring!(T), T))();
    }
    T tuck_head = rt.tuckAt(r.items, 0L);
    T[] tuck_xs = [];
    foreach (tuck_i; 1L .. (tuck_n - 1L) + 1) {
        tuck_xs ~= rt.tuckAt(r.items, tuck_i);
    }
    tuck_Ring!(T) tuck_rest = tuck_Ring!(T)(items: tuck_xs);
    return rt.tok(TRec_rest_value!(tuck_Ring!(T), T)(rest: tuck_rest, value: tuck_head));
}

tuck_Ring!(T) tuck_clear(T)(tuck_Ring!(T) r) {
    r.items = r.items.dup;
    return tuck_clear_moved(r);
}

tuck_Ring!(T) tuck_clear_moved(T)(tuck_Ring!(T) r) {
    T[] tuck_empty = [];
    return tuck_Ring!(T)(items: tuck_empty);
}

T[] tuck_toSeq(T)(tuck_Ring!(T) r) {
    return r.items;
}

long tuck_checkEnds() {
    tuck_Ring!(long) tuck_q = tuck_Ring!(long)(items: []);
    if (!tuck_isEmpty(tuck_q)) {
        return 1L;
    }
    rt.TuckResult!(long) tuck_noEnd = tuck_first(tuck_q);
    if ((tuck_noEnd.status == rt.TuckStatus.Ok)) {
        return 2L;
    }
    tuck_q = tuck_pushBack_moved(tuck_q, 2L);
    tuck_q = tuck_pushBack_moved(tuck_q, 3L);
    tuck_q = tuck_pushFront_moved(tuck_q, 1L);
    if ((tuck_count(tuck_q) != 3L)) {
        return 3L;
    }
    rt.TuckResult!(long) tuck_f = tuck_first(tuck_q);
    if (!(tuck_f.status == rt.TuckStatus.Ok)) {
        return 4L;
    }
    if ((tuck_f.value != 1L)) {
        return 5L;
    }
    rt.TuckResult!(long) tuck_l = tuck_last(tuck_q);
    if (!(tuck_l.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    if ((tuck_l.value != 3L)) {
        return 7L;
    }
    return tuck_checkPops();
}

tuck_Ring!(long) tuck_threeUp() {
    tuck_Ring!(long) tuck_q = tuck_Ring!(long)(items: []);
    tuck_q = tuck_pushBack_moved(tuck_q, 1L);
    tuck_q = tuck_pushBack_moved(tuck_q, 2L);
    return tuck_pushBack(tuck_q, 3L);
}

long tuck_checkPops() {
    tuck_Ring!(long) tuck_q = tuck_threeUp();
    rt.TuckResult!(TRec_rest_value!(tuck_Ring!(long), long)) tuck_back = tuck_popBack(tuck_q);
    if (!(tuck_back.status == rt.TuckStatus.Ok)) {
        return 8L;
    }
    if ((tuck_back.value.value != 3L)) {
        return 9L;
    }
    if ((tuck_count(tuck_back.value.rest) != 2L)) {
        return 10L;
    }
    rt.TuckResult!(TRec_rest_value!(tuck_Ring!(long), long)) tuck_front = tuck_popFront(tuck_q);
    if (!(tuck_front.status == rt.TuckStatus.Ok)) {
        return 11L;
    }
    if ((tuck_front.value.value != 1L)) {
        return 12L;
    }
    if ((tuck_count(tuck_front.value.rest) != 2L)) {
        return 13L;
    }
    if ((tuck_count(tuck_q) != 3L)) {
        return 14L;
    }
    return tuck_checkEmptyPops();
}

long tuck_checkEmptyPops() {
    tuck_Ring!(long) tuck_empty = tuck_Ring!(long)(items: []);
    rt.TuckResult!(TRec_rest_value!(tuck_Ring!(long), long)) tuck_b = tuck_popBack(tuck_empty);
    if ((tuck_b.status == rt.TuckStatus.Ok)) {
        return 15L;
    }
    rt.TuckResult!(TRec_rest_value!(tuck_Ring!(long), long)) tuck_f = tuck_popFront(tuck_empty);
    if ((tuck_f.status == rt.TuckStatus.Ok)) {
        return 16L;
    }
    tuck_Ring!(long) tuck_cleared = tuck_clear(tuck_threeUp());
    if ((tuck_count(tuck_cleared) != 0L)) {
        return 17L;
    }
    long[] tuck_xs = (tuck_toSeq(tuck_threeUp())).dup;
    if ((cast(long) tuck_xs.length != 3L)) {
        return 18L;
    }
    if ((rt.tuckAt(tuck_xs, 0L) != 1L)) {
        return 19L;
    }
    return 0L;
}

long tuck_main() {
    return tuck_checkEnds();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
