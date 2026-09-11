module array;

import rt = tuck_rt;

T tuckArrayAt(N, T)(T[N] items, long index) {
    return rt.tuckArrayAt(items, index);
}

void tuckArraySetAt(N, T)(T[N] items, long index, T value) {
    rt.tuckArraySetAt(items, index, value);
}


rt.TuckResult!(T) tuck_atFixed(size_t N, T)(T[N] items, long index) {
    long tuck_n = cast(long) items.length;
    if (((index < 0L) || (index >= tuck_n))) {
        return rt.tnone!(T)();
    }
    return rt.tok(rt.tuckArrayAt(items, index));
}

rt.TuckResult!(T[N]) tuck_setAtFixed(size_t N, T)(T[N] items, long index, T value) {
    T[N] tuck_out = items;
    if (((index < 0L) || (index >= cast(long) tuck_out.length))) {
        return rt.tnone!(T[N])();
    }
    rt.tuckArraySetAt(tuck_out, index, value);
    return rt.tok(tuck_out);
}

long tuck_countOf(T)(T[] items, T value) {
    long tuck_n = 0L;
    foreach (tuck_i; 0L .. (cast(long) items.length - 1L) + 1) {
        if ((rt.tuckAt(items, tuck_i) == value)) {
            tuck_n = (tuck_n + 1L);
        }
    }
    return tuck_n;
}

T[][] tuck_chunk(T)(T[] items, long size) {
    items = items.dup;
    return tuck_chunk_moved(items, size);
}

T[][] tuck_chunk_moved(T)(T[] items, long size) {
    T[][] tuck_out = [];
    if ((size <= 0L)) {
        return tuck_out;
    }
    long tuck_i = 0L;
    while ((tuck_i < cast(long) items.length)) {
        T[] tuck_piece = [];
        long tuck_j = tuck_i;
        while (((tuck_j < cast(long) items.length) && (tuck_j < (tuck_i + size)))) {
            tuck_piece ~= rt.tuckAt(items, tuck_j);
            tuck_j = (tuck_j + 1L);
        }
        tuck_out ~= tuck_piece;
        tuck_i = (tuck_i + size);
    }
    return tuck_out;
}

struct tuck_Board {
    long[4] cells;
}

long tuck_checkAccess() {
    tuck_Board tuck_b = tuck_Board(cells: [10L, 20L, 30L, 40L]);
    rt.TuckResult!(long) tuck_r0 = tuck_atFixed(tuck_b.cells, 0L);
    if (!(tuck_r0.status == rt.TuckStatus.Ok)) {
        return 1L;
    }
    if ((tuck_r0.value != 10L)) {
        return 2L;
    }
    rt.TuckResult!(long) tuck_bad = tuck_atFixed(tuck_b.cells, 99L);
    if ((tuck_bad.status == rt.TuckStatus.Ok)) {
        return 3L;
    }
    rt.TuckResult!(long[4]) tuck_wrote = tuck_setAtFixed(tuck_b.cells, 1L, 99L);
    if (!(tuck_wrote.status == rt.TuckStatus.Ok)) {
        return 4L;
    }
    rt.TuckResult!(long) tuck_r1 = tuck_atFixed(tuck_wrote.value, 1L);
    if (!(tuck_r1.status == rt.TuckStatus.Ok)) {
        return 5L;
    }
    if ((tuck_r1.value != 99L)) {
        return 6L;
    }
    rt.TuckResult!(long[4]) tuck_failedWrite = tuck_setAtFixed(tuck_b.cells, (0L - 1L), 5L);
    if ((tuck_failedWrite.status == rt.TuckStatus.Ok)) {
        return 7L;
    }
    return 0L;
}

long tuck_checkCountAndChunk() {
    long[] tuck_xs = [1L, 2L, 2L, 3L, 2L, 4L];
    if ((tuck_countOf(tuck_xs, 2L) != 3L)) {
        return 10L;
    }
    if ((tuck_countOf(tuck_xs, 9L) != 0L)) {
        return 11L;
    }
    long[][] tuck_parts = (tuck_chunk(tuck_xs, 4L)).dup;
    if ((cast(long) tuck_parts.length != 2L)) {
        return 12L;
    }
    if (((cast(long) rt.tuckAt(tuck_parts, 0L).length != 4L) || (cast(long) rt.tuckAt(tuck_parts, 1L).length != 2L))) {
        return 13L;
    }
    if (((rt.tuckAt(rt.tuckAt(tuck_parts, 1L), 0L) != 2L) || (rt.tuckAt(rt.tuckAt(tuck_parts, 1L), 1L) != 4L))) {
        return 14L;
    }
    long[] tuck_empty = [];
    long[][] tuck_emptyChunks = (tuck_chunk(tuck_empty, 3L)).dup;
    if ((cast(long) tuck_emptyChunks.length != 0L)) {
        return 15L;
    }
    return 0L;
}

long tuck_main() {
    long tuck_a = tuck_checkAccess();
    if ((tuck_a != 0L)) {
        return tuck_a;
    }
    return tuck_checkCountAndChunk();
}

int main(string[] args) {
    rt.tuckSetArgs(args);
    auto mainRc = tuck_main();
    return cast(int) mainRc;
}
