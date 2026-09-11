module list;

import rt = tuck_rt;

struct tuck_Node(T) {
    T value;
    long next;
    long prev;
}

struct tuck_Chain(T) {
    tuck_Node!(T)[] nodes;
    long head;
    long tail;
    long size;
}

long tuck_nowhere() {
    return (0L - 1L);
}

long tuck_count(T)(tuck_Chain!(T) c) {
    return c.size;
}

bool tuck_isEmpty(T)(tuck_Chain!(T) c) {
    return (c.size == 0L);
}

rt.TuckResult!(T) tuckfn_at(T)(tuck_Chain!(T) c, long pos) {
    if (((pos < 0L) || (pos >= cast(long) c.nodes.length))) {
        return rt.tnone!(T)();
    }
    return rt.tok(rt.tuckAt(c.nodes, pos).value);
}

long tuck_firstPos(T)(tuck_Chain!(T) c) {
    return c.head;
}

long tuck_lastPos(T)(tuck_Chain!(T) c) {
    return c.tail;
}

long tuck_nextPos(T)(tuck_Chain!(T) c, long pos) {
    if (((pos < 0L) || (pos >= cast(long) c.nodes.length))) {
        return tuck_nowhere();
    }
    return rt.tuckAt(c.nodes, pos).next;
}

long tuck_prevPos(T)(tuck_Chain!(T) c, long pos) {
    if (((pos < 0L) || (pos >= cast(long) c.nodes.length))) {
        return tuck_nowhere();
    }
    return rt.tuckAt(c.nodes, pos).prev;
}

rt.TuckResult!(T) tuck_first(T)(tuck_Chain!(T) c) {
    return tuckfn_at(c, c.head);
}

rt.TuckResult!(T) tuck_last(T)(tuck_Chain!(T) c) {
    return tuckfn_at(c, c.tail);
}

tuck_Node!(T)[] tuck_linkNext(T)(tuck_Node!(T)[] ns, long pos, long to) {
    ns = ns.dup;
    return tuck_linkNext_moved(ns, pos, to);
}

tuck_Node!(T)[] tuck_linkNext_moved(T)(tuck_Node!(T)[] ns, long pos, long to) {
    if ((pos < 0L)) {
        return ns;
    }
    tuck_Node!(T)[] tuck_out = ns;
    tuck_Node!(T) tuck_n = rt.tuckAt(tuck_out, pos);
    rt.tuckSetAt(tuck_out, pos, tuck_Node!(T)(value: tuck_n.value, next: to, prev: tuck_n.prev));
    return tuck_out;
}

tuck_Node!(T)[] tuck_linkPrev(T)(tuck_Node!(T)[] ns, long pos, long to) {
    ns = ns.dup;
    return tuck_linkPrev_moved(ns, pos, to);
}

tuck_Node!(T)[] tuck_linkPrev_moved(T)(tuck_Node!(T)[] ns, long pos, long to) {
    if ((pos < 0L)) {
        return ns;
    }
    tuck_Node!(T)[] tuck_out = ns;
    tuck_Node!(T) tuck_n = rt.tuckAt(tuck_out, pos);
    rt.tuckSetAt(tuck_out, pos, tuck_Node!(T)(value: tuck_n.value, next: tuck_n.next, prev: to));
    return tuck_out;
}

tuck_Chain!(T) tuck_append(T)(tuck_Chain!(T) c, T value) {
    c.nodes = c.nodes.dup;
    return tuck_append_moved(c, value);
}

tuck_Chain!(T) tuck_append_moved(T)(tuck_Chain!(T) c, T value) {
    long tuck_slot = cast(long) c.nodes.length;
    tuck_Node!(T)[] tuck_ns = c.nodes;
    tuck_Node!(T) tuck_fresh = tuck_Node!(T)(value: value, next: tuck_nowhere(), prev: c.tail);
    tuck_ns ~= tuck_fresh;
    tuck_ns = tuck_linkNext_moved(tuck_ns, c.tail, tuck_slot);
    long tuck_h = ((c.head < 0L) ? tuck_slot : c.head);
    return tuck_Chain!(T)(nodes: tuck_ns, head: tuck_h, tail: tuck_slot, size: (c.size + 1L));
}

tuck_Chain!(T) tuck_prepend(T)(tuck_Chain!(T) c, T value) {
    c.nodes = c.nodes.dup;
    return tuck_prepend_moved(c, value);
}

tuck_Chain!(T) tuck_prepend_moved(T)(tuck_Chain!(T) c, T value) {
    long tuck_slot = cast(long) c.nodes.length;
    tuck_Node!(T)[] tuck_ns = c.nodes;
    tuck_Node!(T) tuck_fresh = tuck_Node!(T)(value: value, next: c.head, prev: tuck_nowhere());
    tuck_ns ~= tuck_fresh;
    tuck_ns = tuck_linkPrev_moved(tuck_ns, c.head, tuck_slot);
    long tuck_t = ((c.tail < 0L) ? tuck_slot : c.tail);
    return tuck_Chain!(T)(nodes: tuck_ns, head: tuck_slot, tail: tuck_t, size: (c.size + 1L));
}

tuck_Chain!(T) tuck_insertAfter(T)(tuck_Chain!(T) c, long pos, T value) {
    c.nodes = c.nodes.dup;
    return tuck_insertAfter_moved(c, pos, value);
}

tuck_Chain!(T) tuck_insertAfter_moved(T)(tuck_Chain!(T) c, long pos, T value) {
    if (((pos < 0L) || (pos >= cast(long) c.nodes.length))) {
        return c;
    }
    long tuck_slot = cast(long) c.nodes.length;
    long tuck_after = rt.tuckAt(c.nodes, pos).next;
    tuck_Node!(T)[] tuck_ns = c.nodes;
    tuck_Node!(T) tuck_fresh = tuck_Node!(T)(value: value, next: tuck_after, prev: pos);
    tuck_ns ~= tuck_fresh;
    tuck_ns = tuck_linkNext_moved(tuck_ns, pos, tuck_slot);
    tuck_ns = tuck_linkPrev_moved(tuck_ns, tuck_after, tuck_slot);
    long tuck_t = ((tuck_after < 0L) ? tuck_slot : c.tail);
    return tuck_Chain!(T)(nodes: tuck_ns, head: c.head, tail: tuck_t, size: (c.size + 1L));
}

tuck_Chain!(T) tuck_removeAt(T)(tuck_Chain!(T) c, long pos) {
    c.nodes = c.nodes.dup;
    return tuck_removeAt_moved(c, pos);
}

tuck_Chain!(T) tuck_removeAt_moved(T)(tuck_Chain!(T) c, long pos) {
    if (((pos < 0L) || (pos >= cast(long) c.nodes.length))) {
        return c;
    }
    long tuck_before = rt.tuckAt(c.nodes, pos).prev;
    long tuck_after = rt.tuckAt(c.nodes, pos).next;
    tuck_Node!(T)[] tuck_ns = c.nodes;
    tuck_ns = tuck_linkNext_moved(tuck_ns, tuck_before, tuck_after);
    tuck_ns = tuck_linkPrev_moved(tuck_ns, tuck_after, tuck_before);
    long tuck_h = ((pos == c.head) ? tuck_after : c.head);
    long tuck_t = ((pos == c.tail) ? tuck_before : c.tail);
    return tuck_Chain!(T)(nodes: tuck_ns, head: tuck_h, tail: tuck_t, size: (c.size - 1L));
}

T[] tuck_toSeq(T)(tuck_Chain!(T) c) {
    T[] tuck_out = [];
    long tuck_pos = c.head;
    while ((tuck_pos >= 0L)) {
        tuck_out ~= rt.tuckAt(c.nodes, tuck_pos).value;
        tuck_pos = rt.tuckAt(c.nodes, tuck_pos).next;
    }
    return tuck_out;
}

tuck_Chain!(T) tuckfn_concat(T)(tuck_Chain!(T) a, tuck_Chain!(T) b) {
    a.nodes = a.nodes.dup;
    return tuckfn_concat_moved(a, b);
}

tuck_Chain!(T) tuckfn_concat_moved(T)(tuck_Chain!(T) a, tuck_Chain!(T) b) {
    tuck_Chain!(T) tuck_out = a;
    T[] tuck_bs = (tuck_toSeq(b)).dup;
    foreach (tuck_i; 0L .. (cast(long) tuck_bs.length - 1L) + 1) {
        tuck_out = tuck_append_moved(tuck_out, rt.tuckAt(tuck_bs, tuck_i));
    }
    return tuck_out;
}

tuck_Chain!(long) tuck_emptyChain() {
    return tuck_Chain!(long)(nodes: [], head: tuck_nowhere(), tail: tuck_nowhere(), size: 0L);
}

tuck_Chain!(long) tuck_oneTwoThree() {
    tuck_Chain!(long) tuck_c = tuck_emptyChain();
    tuck_c = tuck_append_moved(tuck_c, 1L);
    tuck_c = tuck_append_moved(tuck_c, 2L);
    return tuck_append(tuck_c, 3L);
}

long tuck_checkBuild() {
    tuck_Chain!(long) tuck_e = tuck_emptyChain();
    if (!tuck_isEmpty(tuck_e)) {
        return 1L;
    }
    rt.TuckResult!(long) tuck_noHead = tuck_first(tuck_e);
    if ((tuck_noHead.status == rt.TuckStatus.Ok)) {
        return 2L;
    }
    tuck_Chain!(long) tuck_c = tuck_oneTwoThree();
    if ((tuck_count(tuck_c) != 3L)) {
        return 3L;
    }
    rt.TuckResult!(long) tuck_f = tuck_first(tuck_c);
    if (!(tuck_f.status == rt.TuckStatus.Ok)) {
        return 4L;
    }
    if ((tuck_f.value != 1L)) {
        return 5L;
    }
    rt.TuckResult!(long) tuck_l = tuck_last(tuck_c);
    if (!(tuck_l.status == rt.TuckStatus.Ok)) {
        return 6L;
    }
    if ((tuck_l.value != 3L)) {
        return 7L;
    }
    return tuck_checkOrder();
}

long tuck_checkOrder() {
    long[] tuck_xs = (tuck_toSeq(tuck_oneTwoThree())).dup;
    if ((cast(long) tuck_xs.length != 3L)) {
        return 8L;
    }
    if ((rt.tuckAt(tuck_xs, 0L) != 1L)) {
        return 9L;
    }
    if ((rt.tuckAt(tuck_xs, 2L) != 3L)) {
        return 10L;
    }
    tuck_Chain!(long) tuck_p = tuck_prepend(tuck_oneTwoThree(), 0L);
    long[] tuck_ps = (tuck_toSeq(tuck_p)).dup;
    if ((rt.tuckAt(tuck_ps, 0L) != 0L)) {
        return 11L;
    }
    if ((rt.tuckAt(tuck_ps, 3L) != 3L)) {
        return 12L;
    }
    return tuck_checkHandles();
}

long tuck_checkHandles() {
    tuck_Chain!(long) tuck_c = tuck_oneTwoThree();
    long tuck_head = tuck_firstPos(tuck_c);
    long tuck_second = tuck_nextPos(tuck_c, tuck_head);
    rt.TuckResult!(long) tuck_v = tuckfn_at(tuck_c, tuck_second);
    if (!(tuck_v.status == rt.TuckStatus.Ok)) {
        return 13L;
    }
    if ((tuck_v.value != 2L)) {
        return 14L;
    }
    tuck_Chain!(long) tuck_ins = tuck_insertAfter(tuck_c, tuck_second, 99L);
    long[] tuck_isq = (tuck_toSeq(tuck_ins)).dup;
    if ((cast(long) tuck_isq.length != 4L)) {
        return 15L;
    }
    if ((rt.tuckAt(tuck_isq, 2L) != 99L)) {
        return 16L;
    }
    return tuck_checkRemoval();
}

long tuck_checkRemoval() {
    tuck_Chain!(long) tuck_c = tuck_oneTwoThree();
    long tuck_head = tuck_firstPos(tuck_c);
    long tuck_second = tuck_nextPos(tuck_c, tuck_head);
    tuck_Chain!(long) tuck_cut = tuck_removeAt(tuck_c, tuck_second);
    if ((tuck_count(tuck_cut) != 2L)) {
        return 17L;
    }
    long[] tuck_cs = (tuck_toSeq(tuck_cut)).dup;
    if ((cast(long) tuck_cs.length != 2L)) {
        return 18L;
    }
    if ((rt.tuckAt(tuck_cs, 0L) != 1L)) {
        return 19L;
    }
    if ((rt.tuckAt(tuck_cs, 1L) != 3L)) {
        return 20L;
    }
    long tuck_head2 = tuck_firstPos(tuck_c);
    tuck_Chain!(long) tuck_noHead = tuck_removeAt(tuck_c, tuck_head2);
    long[] tuck_hs = (tuck_toSeq(tuck_noHead)).dup;
    if ((rt.tuckAt(tuck_hs, 0L) != 2L)) {
        return 21L;
    }
    if ((tuck_count(tuck_c) != 3L)) {
        return 22L;
    }
    return tuck_checkConcat();
}

long tuck_checkConcat() {
    tuck_Chain!(long) tuck_joined = tuckfn_concat(tuck_oneTwoThree(), tuck_oneTwoThree());
    if ((tuck_count(tuck_joined) != 6L)) {
        return 23L;
    }
    long[] tuck_js = (tuck_toSeq(tuck_joined)).dup;
    if ((cast(long) tuck_js.length != 6L)) {
        return 24L;
    }
    if ((rt.tuckAt(tuck_js, 3L) != 1L)) {
        return 25L;
    }
    return 0L;
}

long tuck_main() {
    return tuck_checkBuild();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
