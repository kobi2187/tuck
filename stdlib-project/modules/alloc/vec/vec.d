module vec;

import rt = tuck_rt;

struct TRec_rest_value(T_rest, T_value) {
    T_rest rest;
    T_value value;
}

long tuck_count(T)(T[] items) {
    return cast(long) items.length;
}

bool tuck_isEmpty(T)(T[] items) {
    return (cast(long) items.length == 0L);
}

rt.TuckResult!(T) tuckfn_at(T)(T[] items, long index) {
    if (((index < 0L) || (index >= cast(long) items.length))) {
        return rt.tnone!(T)();
    }
    return rt.tok(rt.tuckAt(items, index));
}

rt.TuckResult!(T) tuck_first(T)(T[] items) {
    return tuckfn_at(items, 0L);
}

rt.TuckResult!(T) tuck_last(T)(T[] items) {
    return tuckfn_at(items, (cast(long) items.length - 1L));
}

T[] tuckfn_setAt(T)(T[] items, long index, T value) {
    items = items.dup;
    return tuckfn_setAt_moved(items, index, value);
}

T[] tuckfn_setAt_moved(T)(T[] items, long index, T value) {
    if (((index < 0L) || (index >= cast(long) items.length))) {
        return items;
    }
    T[] tuck_out = items;
    rt.tuckSetAt(tuck_out, index, value);
    return tuck_out;
}

T[] tuck_clear(T)(T[] items) {
    items = items.dup;
    return tuck_clear_moved(items);
}

T[] tuck_clear_moved(T)(T[] items) {
    T[] tuck_empty = [];
    return tuck_empty;
}

bool tuck_has(T)(T[] items, T value) {
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        if ((rt.tuckAt(items, tuck_i) == value)) {
            return true;
        }
    }
    return false;
}

rt.TuckResult!(long) tuck_indexOf(T)(T[] items, T value) {
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        if ((rt.tuckAt(items, tuck_i) == value)) {
            return rt.tok(tuck_i);
        }
    }
    return rt.tnone!(long)();
}

T[] tuck_insertAt(T)(T[] items, long index, T value) {
    items = items.dup;
    return tuck_insertAt_moved(items, index, value);
}

T[] tuck_insertAt_moved(T)(T[] items, long index, T value) {
    T[] tuck_out = [];
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        if ((tuck_i == index)) {
            tuck_out ~= value;
        }
        tuck_out ~= rt.tuckAt(items, tuck_i);
    }
    if ((index >= cast(long) items.length)) {
        tuck_out ~= value;
    }
    return tuck_out;
}

T[] tuck_removeAt(T)(T[] items, long index) {
    items = items.dup;
    return tuck_removeAt_moved(items, index);
}

T[] tuck_removeAt_moved(T)(T[] items, long index) {
    T[] tuck_out = [];
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        if ((tuck_i != index)) {
            tuck_out ~= rt.tuckAt(items, tuck_i);
        }
    }
    return tuck_out;
}

rt.TuckResult!(TRec_rest_value!(T[], T)) tuck_pop(T)(T[] items) {
    if ((cast(long) items.length == 0L)) {
        return rt.tnone!(TRec_rest_value!(T[], T))();
    }
    T tuck_top = rt.tuckAt(items, (cast(long) items.length - 1L));
    T[] tuck_rest = (tuck_removeAt(items, (cast(long) items.length - 1L))).dup;
    return rt.tok(TRec_rest_value!(T[], T)(rest: tuck_rest, value: tuck_top));
}

long tuck_checkReads() {
    long[] tuck_xs = [10L, 20L, 30L];
    if ((tuck_count(tuck_xs) != 3L)) {
        return 1L;
    }
    long[] tuck_empty = [];
    if (!tuck_isEmpty(tuck_empty)) {
        return 2L;
    }
    rt.TuckResult!(long) tuck_got = tuckfn_at(tuck_xs, 1L);
    if (!(tuck_got.status == rt.TuckStatus.Ok)) {
        return 3L;
    }
    if ((tuck_got.value != 20L)) {
        return 4L;
    }
    rt.TuckResult!(long) tuck_past = tuckfn_at(tuck_xs, 9L);
    if ((tuck_past.status == rt.TuckStatus.Ok)) {
        return 5L;
    }
    return tuck_checkEnds();
}

long tuck_checkEnds() {
    long[] tuck_xs = [10L, 20L, 30L];
    rt.TuckResult!(long) tuck_f = tuck_first(tuck_xs);
    if (!(tuck_f.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    if ((tuck_f.value != 10L)) {
        return 7L;
    }
    rt.TuckResult!(long) tuck_l = tuck_last(tuck_xs);
    if (!(tuck_l.status == rt.TuckStatus.Ok)) {
        return 8L;
    }
    if ((tuck_l.value != 30L)) {
        return 9L;
    }
    long[] tuck_empty = [];
    rt.TuckResult!(long) tuck_absent = tuck_first(tuck_empty);
    if ((tuck_absent.status == rt.TuckStatus.Ok)) {
        return 10L;
    }
    return tuck_checkSearch();
}

long tuck_checkSearch() {
    long[] tuck_xs = [10L, 20L, 30L];
    if (!tuck_has(tuck_xs, 20L)) {
        return 11L;
    }
    if (tuck_has(tuck_xs, 99L)) {
        return 12L;
    }
    rt.TuckResult!(long) tuck_idx = tuck_indexOf(tuck_xs, 30L);
    if (!(tuck_idx.status == rt.TuckStatus.Ok)) {
        return 13L;
    }
    if ((tuck_idx.value != 2L)) {
        return 14L;
    }
    rt.TuckResult!(long) tuck_missing = tuck_indexOf(tuck_xs, 99L);
    if ((tuck_missing.status == rt.TuckStatus.Ok)) {
        return 15L;
    }
    return tuck_checkEdits();
}

long tuck_checkEdits() {
    long[] tuck_xs = [10L, 20L, 30L];
    long[] tuck_set = (tuckfn_setAt(tuck_xs, 1L, 99L)).dup;
    if ((rt.tuckAt(tuck_set, 1L) != 99L)) {
        return 16L;
    }
    if ((rt.tuckAt(tuck_xs, 1L) != 20L)) {
        return 17L;
    }
    long[] tuck_ins = (tuck_insertAt(tuck_xs, 1L, 15L)).dup;
    if ((cast(long) tuck_ins.length != 4L)) {
        return 18L;
    }
    if ((rt.tuckAt(tuck_ins, 1L) != 15L)) {
        return 19L;
    }
    long[] tuck_del = (tuck_removeAt(tuck_xs, 0L)).dup;
    if ((cast(long) tuck_del.length != 2L)) {
        return 20L;
    }
    if ((rt.tuckAt(tuck_del, 0L) != 20L)) {
        return 21L;
    }
    return tuck_checkPop();
}

long tuck_checkPop() {
    long[] tuck_xs = [10L, 20L, 30L];
    rt.TuckResult!(TRec_rest_value!(long[], long)) tuck_p = tuck_pop(tuck_xs);
    if (!(tuck_p.status == rt.TuckStatus.Ok)) {
        return 22L;
    }
    if ((tuck_p.value.value != 30L)) {
        return 23L;
    }
    if ((cast(long) tuck_p.value.rest.length != 2L)) {
        return 24L;
    }
    long[] tuck_empty = [];
    rt.TuckResult!(TRec_rest_value!(long[], long)) tuck_absent = tuck_pop(tuck_empty);
    if ((tuck_absent.status == rt.TuckStatus.Ok)) {
        return 25L;
    }
    long[] tuck_cleared = (tuck_clear(tuck_xs)).dup;
    if ((cast(long) tuck_cleared.length != 0L)) {
        return 26L;
    }
    return 0L;
}

long tuck_main() {
    return tuck_checkReads();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
