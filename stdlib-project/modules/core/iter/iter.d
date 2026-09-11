module iter;

import rt = tuck_rt;
import seq = mod_seq;

struct TRec_index_value(T_index, T_value) {
    T_index index;
    T_value value;
}

struct TRec_left_right(T_left, T_right) {
    T_left left;
    T_right right;
}

U[] tuck_map(T, U)(T[] items, U function(T) f) {
    items = items.dup;
    return tuck_map_moved(items, f);
}

U[] tuck_map_moved(T, U)(T[] items, U function(T) f) {
    U[] tuck_out = [];
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        U tuck_v = f(rt.tuckAt(items, tuck_i));
        tuck_out ~= tuck_v;
    }
    return tuck_out;
}

T[] tuck_filter(T)(T[] items, bool function(T) test) {
    items = items.dup;
    return tuck_filter_moved(items, test);
}

T[] tuck_filter_moved(T)(T[] items, bool function(T) test) {
    T[] tuck_out = [];
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        T tuck_v = rt.tuckAt(items, tuck_i);
        if (test(tuck_v)) {
            tuck_out ~= tuck_v;
        }
    }
    return tuck_out;
}

T[] tuck_reject(T)(T[] items, bool function(T) test) {
    items = items.dup;
    return tuck_reject_moved(items, test);
}

T[] tuck_reject_moved(T)(T[] items, bool function(T) test) {
    T[] tuck_out = [];
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        T tuck_v = rt.tuckAt(items, tuck_i);
        if (!test(tuck_v)) {
            tuck_out ~= tuck_v;
        }
    }
    return tuck_out;
}

T[] tuck_take(T)(T[] items, long n) {
    items = items.dup;
    return tuck_take_moved(items, n);
}

T[] tuck_take_moved(T)(T[] items, long n) {
    T[] tuck_out = [];
    long tuck_i = 0L;
    while (((tuck_i < cast(long) items.length) && (tuck_i < n))) {
        tuck_out ~= rt.tuckAt(items, tuck_i);
        tuck_i = (tuck_i + 1L);
    }
    return tuck_out;
}

T[] tuck_skip(T)(T[] items, long n) {
    items = items.dup;
    return tuck_skip_moved(items, n);
}

T[] tuck_skip_moved(T)(T[] items, long n) {
    T[] tuck_out = [];
    long tuck_i = n;
    while ((tuck_i < cast(long) items.length)) {
        tuck_out ~= rt.tuckAt(items, tuck_i);
        tuck_i = (tuck_i + 1L);
    }
    return tuck_out;
}

TRec_index_value!(long, T)[] tuck_numbered(T)(T[] items) {
    items = items.dup;
    return tuck_numbered_moved(items);
}

TRec_index_value!(long, T)[] tuck_numbered_moved(T)(T[] items) {
    TRec_index_value!(long, T)[] tuck_out = [];
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        tuck_out ~= TRec_index_value!(long, T)(index: tuck_i, value: rt.tuckAt(items, tuck_i));
    }
    return tuck_out;
}

TRec_left_right!(T, U)[] tuck_zip(T, U)(T[] items, U[] other) {
    items = items.dup;
    return tuck_zip_moved(items, other);
}

TRec_left_right!(T, U)[] tuck_zip_moved(T, U)(T[] items, U[] other) {
    TRec_left_right!(T, U)[] tuck_out = [];
    long tuck_n = cast(long) items.length;
    if ((cast(long) other.length < tuck_n)) {
        tuck_n = cast(long) other.length;
    }
    long tuck_i = 0L;
    while ((tuck_i < tuck_n)) {
        tuck_out ~= TRec_left_right!(T, U)(left: rt.tuckAt(items, tuck_i), right: rt.tuckAt(other, tuck_i));
        tuck_i = (tuck_i + 1L);
    }
    return tuck_out;
}

T[] tuck_append(T)(T[] items, T[] other) {
    items = items.dup;
    return tuck_append_moved(items, other);
}

T[] tuck_append_moved(T)(T[] items, T[] other) {
    T[] tuck_out = items;
    foreach (tuck_i; 0L .. (cast(long) other.length - 1L) + 1) {
        tuck_out ~= rt.tuckAt(other, tuck_i);
    }
    return tuck_out;
}

T[] tuck_prepend(T)(T[] items, T[] other) {
    items = items.dup;
    return tuck_prepend_moved(items, other);
}

T[] tuck_prepend_moved(T)(T[] items, T[] other) {
    T[] tuck_out = (other).dup;
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        tuck_out ~= rt.tuckAt(items, tuck_i);
    }
    return tuck_out;
}

T[] tuckfn_concat(T)(T[][] items) {
    items = items.dup;
    return tuckfn_concat_moved(items);
}

T[] tuckfn_concat_moved(T)(T[][] items) {
    T[] tuck_out = [];
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        T[] tuck_inner = (rt.tuckAt(items, tuck_i)).dup;
        foreach (tuck_j; 0L .. (cast(long) tuck_inner.length - 1L) + 1) {
            tuck_out ~= rt.tuckAt(tuck_inner, tuck_j);
        }
    }
    return tuck_out;
}

T[] tuck_reverse(T)(T[] items) {
    items = items.dup;
    return tuck_reverse_moved(items);
}

T[] tuck_reverse_moved(T)(T[] items) {
    T[] tuck_out = [];
    long tuck_i = (cast(long) items.length - 1L);
    while ((tuck_i >= 0L)) {
        tuck_out ~= rt.tuckAt(items, tuck_i);
        tuck_i = (tuck_i - 1L);
    }
    return tuck_out;
}

A tuck_reduce(T, A)(T[] items, A start, A function(A, T) combine) {
    A tuck_acc = start;
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        tuck_acc = combine(tuck_acc, rt.tuckAt(items, tuck_i));
    }
    return tuck_acc;
}

void tuck_each(T)(T[] items, void function(T) f) {
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        f(rt.tuckAt(items, tuck_i));
    }
}

rt.TuckResult!(T) tuck_find(T)(T[] items, bool function(T) test) {
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        T tuck_v = rt.tuckAt(items, tuck_i);
        if (test(tuck_v)) {
            return rt.tok(tuck_v);
        }
    }
    return rt.tnone!(T)();
}

bool tuck_any(T)(T[] items, bool function(T) test) {
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        if (test(rt.tuckAt(items, tuck_i))) {
            return true;
        }
    }
    return false;
}

bool tuck_all(T)(T[] items, bool function(T) test) {
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        if (!test(rt.tuckAt(items, tuck_i))) {
            return false;
        }
    }
    return true;
}

rt.TuckResult!(T) tuck_sum(T)(T[] items) {
    if ((cast(long) items.length == 0L)) {
        return rt.tnone!(T)();
    }
    T tuck_acc = rt.tuckAt(items, 0L);
    foreach (tuck_i; 1L .. (cast(long) items.length - 1L) + 1) {
        tuck_acc = (tuck_acc + rt.tuckAt(items, tuck_i));
    }
    return rt.tok(tuck_acc);
}

T[] tuck_sort(T)(T[] items) {
    items = items.dup;
    return tuck_sort_moved(items);
}

T[] tuck_sort_moved(T)(T[] items) {
    T[] tuck_out = items;
    long tuck_i = 1L;
    while ((tuck_i < cast(long) tuck_out.length)) {
        T tuck_key = rt.tuckAt(tuck_out, tuck_i);
        long tuck_j = (tuck_i - 1L);
        while (((tuck_j >= 0L) && (rt.tuckAt(tuck_out, tuck_j) > tuck_key))) {
            seq.setAt(tuck_out, (tuck_j + 1L), rt.tuckAt(tuck_out, tuck_j));
            tuck_j = (tuck_j - 1L);
        }
        seq.setAt(tuck_out, (tuck_j + 1L), tuck_key);
        tuck_i = (tuck_i + 1L);
    }
    return tuck_out;
}

bool tuck_isPositive(long x) {
    return (x > 0L);
}

long tuck_double(long x) {
    return (x * 2L);
}

long tuck_addUp(long acc, long x) {
    return (acc + x);
}

void tuck_recordEach(long x) {
    return;
}

long tuck_checkFilterMap() {
    long[] tuck_xs = [(0L - 3L), 1L, 4L, (0L - 1L), 5L, 9L];
    long[] tuck_live = (tuck_filter(tuck_xs, &tuck_isPositive)).dup;
    if ((cast(long) tuck_live.length != 4L)) {
        return 1L;
    }
    long[] tuck_doubled = (tuck_map(tuck_live, &tuck_double)).dup;
    if (((rt.tuckAt(tuck_doubled, 0L) != 2L) || (rt.tuckAt(tuck_doubled, 3L) != 18L))) {
        return 2L;
    }
    long[] tuck_gone = (tuck_reject(tuck_xs, &tuck_isPositive)).dup;
    if ((cast(long) tuck_gone.length != 2L)) {
        return 3L;
    }
    return 0L;
}

long tuck_checkSlices() {
    long[] tuck_xs = [(0L - 3L), 1L, 4L, (0L - 1L), 5L, 9L];
    long[] tuck_first2 = (tuck_take(tuck_xs, 2L)).dup;
    if (((cast(long) tuck_first2.length != 2L) || (rt.tuckAt(tuck_first2, 1L) != 1L))) {
        return 4L;
    }
    long[] tuck_rest = (tuck_skip(tuck_xs, 2L)).dup;
    if (((cast(long) tuck_rest.length != (cast(long) tuck_xs.length - 2L)) || (rt.tuckAt(tuck_rest, 0L) != 4L))) {
        return 5L;
    }
    TRec_index_value!(long, long)[] tuck_nums = (tuck_numbered(tuck_xs)).dup;
    if (((rt.tuckAt(tuck_nums, 0L).index != 0L) || (rt.tuckAt(tuck_nums, 2L).value != 4L))) {
        return 6L;
    }
    return 0L;
}

long tuck_checkJoins() {
    long[] tuck_xs = [(0L - 3L), 1L, 4L, (0L - 1L), 5L, 9L];
    long[] tuck_first2 = (tuck_take(tuck_xs, 2L)).dup;
    long[] tuck_rest = (tuck_skip(tuck_xs, 2L)).dup;
    long[] tuck_ys = [10L, 20L];
    TRec_left_right!(long, long)[] tuck_paired = (tuck_zip(tuck_xs, tuck_ys)).dup;
    if (((cast(long) tuck_paired.length != 2L) || ((rt.tuckAt(tuck_paired, 1L).left != 1L) || (rt.tuckAt(tuck_paired, 1L).right != 20L)))) {
        return 7L;
    }
    long[] tuck_joined = (tuck_append(tuck_first2, tuck_rest)).dup;
    if ((cast(long) tuck_joined.length != cast(long) tuck_xs.length)) {
        return 8L;
    }
    long[] tuck_front = (tuck_prepend(tuck_rest, tuck_first2)).dup;
    if (((cast(long) tuck_front.length != cast(long) tuck_xs.length) || (rt.tuckAt(tuck_front, 0L) != rt.tuckAt(tuck_first2, 0L)))) {
        return 9L;
    }
    long[][] tuck_nested = [tuck_first2, tuck_rest];
    long[] tuck_flat = (tuckfn_concat(tuck_nested)).dup;
    if ((cast(long) tuck_flat.length != cast(long) tuck_xs.length)) {
        return 10L;
    }
    long[] tuck_backwards = (tuck_reverse(tuck_first2)).dup;
    if (((rt.tuckAt(tuck_backwards, 0L) != rt.tuckAt(tuck_first2, 1L)) || (rt.tuckAt(tuck_backwards, 1L) != rt.tuckAt(tuck_first2, 0L)))) {
        return 11L;
    }
    return 0L;
}

long tuck_checkAdapters() {
    long tuck_a = tuck_checkFilterMap();
    if ((tuck_a != 0L)) {
        return tuck_a;
    }
    long tuck_b = tuck_checkSlices();
    if ((tuck_b != 0L)) {
        return tuck_b;
    }
    return tuck_checkJoins();
}

long tuck_checkReduceFind() {
    long[] tuck_xs = [(0L - 3L), 1L, 4L, (0L - 1L), 5L, 9L];
    long tuck_total = tuck_reduce(tuck_xs, 0L, &tuck_addUp);
    if ((tuck_total != 15L)) {
        return 20L;
    }
    tuck_each(tuck_xs, &tuck_recordEach);
    rt.TuckResult!(long) tuck_hit = tuck_find(tuck_xs, &tuck_isPositive);
    if (!(tuck_hit.status == rt.TuckStatus.Ok)) {
        return 21L;
    }
    if ((tuck_hit.value != 1L)) {
        return 21L;
    }
    rt.TuckResult!(long) tuck_noneHit = tuck_find([(0L - 1L), (0L - 2L)], &tuck_isPositive);
    if ((tuck_noneHit.status == rt.TuckStatus.Ok)) {
        return 22L;
    }
    return 0L;
}

long tuck_checkPredicates() {
    long[] tuck_xs = [(0L - 3L), 1L, 4L, (0L - 1L), 5L, 9L];
    if (!tuck_any(tuck_xs, &tuck_isPositive)) {
        return 23L;
    }
    if (tuck_all(tuck_xs, &tuck_isPositive)) {
        return 24L;
    }
    long[] tuck_miss = (tuck_filter(tuck_xs, &tuck_isPositive)).dup;
    rt.TuckResult!(long) tuck_total = tuck_sum(tuck_miss);
    if (!(tuck_total.status == rt.TuckStatus.Ok)) {
        return 25L;
    }
    if ((tuck_total.value != 19L)) {
        return 25L;
    }
    long[] tuck_noItems = [];
    rt.TuckResult!(long) tuck_emptySum = tuck_sum(tuck_noItems);
    if ((tuck_emptySum.status == rt.TuckStatus.Ok)) {
        return 26L;
    }
    return 0L;
}

long tuck_checkTerminals() {
    long tuck_a = tuck_checkReduceFind();
    if ((tuck_a != 0L)) {
        return tuck_a;
    }
    return tuck_checkPredicates();
}

long tuck_checkOrder() {
    long[] tuck_xs = [5L, 3L, (0L - 1L), 4L, 4L, 9L, 0L];
    long[] tuck_sorted = (tuck_sort(tuck_xs)).dup;
    long tuck_i = 1L;
    while ((tuck_i < cast(long) tuck_sorted.length)) {
        if ((rt.tuckAt(tuck_sorted, (tuck_i - 1L)) > rt.tuckAt(tuck_sorted, tuck_i))) {
            return 30L;
        }
        tuck_i = (tuck_i + 1L);
    }
    if (((rt.tuckAt(tuck_sorted, 0L) != (0L - 1L)) || (rt.tuckAt(tuck_sorted, (cast(long) tuck_sorted.length - 1L)) != 9L))) {
        return 31L;
    }
    return 0L;
}

long tuck_main() {
    long tuck_a = tuck_checkAdapters();
    if ((tuck_a != 0L)) {
        return tuck_a;
    }
    long tuck_t = tuck_checkTerminals();
    if ((tuck_t != 0L)) {
        return tuck_t;
    }
    return tuck_checkOrder();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
